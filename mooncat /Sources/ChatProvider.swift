import Foundation

struct ChatMessage {
    enum Role { case user, assistant }
    let role: Role
    let text: String
}

struct ToolCall {
    let id: String
    let name: String
    let args: [String: Any]
}

enum ToolStep {
    case text(String)
    case calls([ToolCall])
}

/// A conversation kept in the provider's own message format, so tool calls and their
/// results can be replayed to it. Tools are not offered to Ollama.
final class ToolSession {
    let kind: ChatProviderKind
    fileprivate(set) var raw: [[String: Any]] = []

    init(kind: ChatProviderKind, history: [ChatMessage]) {
        self.kind = kind
        for m in history { addText(m.text, user: m.role == .user) }
    }

    func addText(_ t: String, user: Bool) {
        if kind == .gemini {
            raw.append(["role": user ? "user" : "model", "parts": [["text": t]]])
        } else {
            raw.append(["role": user ? "user" : "assistant", "content": t])
        }
    }

    fileprivate func addResults(_ pairs: [(ToolCall, String)]) {
        if kind == .gemini {
            let parts = pairs.map { p -> [String: Any] in
                ["functionResponse": ["name": p.0.name, "response": ["result": p.1]]]
            }
            raw.append(["role": "user", "parts": parts])
        } else {
            for (c, r) in pairs { raw.append(["role": "tool", "tool_call_id": c.id, "content": r]) }
        }
    }
}

enum ChatError: LocalizedError {
    case disabled
    case notConfigured(String)
    case noInternet
    case ollamaNotRunning
    case unauthorized
    case modelNotFound
    case rateLimited(Int?)
    case server(Int)
    case blocked
    case badResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .disabled: return "Chat is off. Turn it on in Chat settings."
        case .notConfigured(let s): return s
        case .noInternet: return "I can't reach the internet right now."
        case .ollamaNotRunning: return "I can't find Ollama. Start it, then try again."
        case .unauthorized: return "That API key was rejected. Check it in Chat settings."
        case .modelNotFound: return "The provider doesn't know that model name. In Chat settings, press “Find models” and pick one."
        case .rateLimited(let secs):
            if let s = secs { return "Free limit reached. Try again in about \(s) seconds." }
            return "Free limit reached. Try again in a little while."
        case .server(let code): return "The provider had a problem (HTTP \(code)). Try again soon."
        case .blocked: return "The provider wouldn't answer that one."
        case .badResponse: return "I couldn't understand the provider's reply."
        case .timedOut: return "That took too long. Try again."
        }
    }
}

/// Talks to Gemini, any OpenAI-style server (Groq, OpenRouter, …) or a local Ollama.
/// Network calls happen ONLY inside `send`, which the chat window calls when you press Send
/// (and the settings "Test" button). Nothing is requested at launch or while chat is off.
final class ChatClient {
    private var task: URLSessionDataTask?
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        session = URLSession(configuration: cfg)
    }

    var isBusy: Bool { return task != nil }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// `completion` is always called on the main thread.
    func send(_ messages: [ChatMessage], retried: Bool = false, completion: @escaping (Result<String, ChatError>) -> Void) {
        let st = Settings.shared
        guard st.chatEnabled else { return finish(.failure(.disabled), completion) }
        let kind = st.chatProviderKind
        var key = ""
        if kind.needsKey {
            switch Self.loadKey(kind) {
            case .success(let k): key = k
            case .failure(let e): return finish(.failure(e), completion)
            }
        }
        let model = st.chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty { return finish(.failure(.notConfigured("Pick a model in Chat settings.")), completion) }

        let system = st.chatPersonality
        guard let request = Self.makeRequest(kind: kind, model: model, baseURL: st.chatBaseURL,
                                             key: key, system: system, messages: messages) else {
            return finish(.failure(.notConfigured("The server address in Chat settings isn't valid.")), completion)
        }

        cancel()
        let t = session.dataTask(with: request) { [weak self] data, response, error in
            let result = Self.parse(kind: kind, data: data, response: response, error: error)
            DispatchQueue.main.async {
                // A cancelled request was replaced or stopped by the caller: say nothing.
                if (error as? URLError)?.code == .cancelled { return }
                guard let self = self else { return }
                self.task = nil
                // Google retires model names now and then. If the saved one is gone, find a
                // current one, remember it, and try once more.
                if case .failure(.modelNotFound) = result, kind == .gemini, !retried {
                    self.task = nil
                    self.listModels(kind: .gemini) { names in
                        if let better = names.first(where: { $0 != model }) {
                            Settings.shared.chatModel = better
                            self.send(messages, retried: true, completion: completion)
                        } else {
                            completion(result)
                        }
                    }
                    return
                }
                completion(result)
            }
        }
        task = t
        t.resume()
    }

    /// The saved API key, or an error that says what is actually wrong.
    private static func loadKey(_ kind: ChatProviderKind) -> Result<String, ChatError> {
        do {
            guard let k = try KeychainStore.read(account: kind.keyAccount), !k.isEmpty else {
                return .failure(.notConfigured("No API key is saved. Open Chat settings and paste it again (keys saved before the MoonCat password update need pasting once more)."))
            }
            return .success(k)
        } catch {
            return .failure(.notConfigured(error.localizedDescription))
        }
    }

    static func supportsTools(_ kind: ChatProviderKind) -> Bool { return kind != .ollama }

    /// One round with tools switched on. The model's reply is added to `session`.
    /// `completion` is always called on the main thread (except after `cancel()`, which stays silent).
    func step(_ session: ToolSession, system: String,
              completion: @escaping (Result<ToolStep, ChatError>) -> Void) {
        func fail(_ e: ChatError) { DispatchQueue.main.async { completion(.failure(e)) } }
        let st = Settings.shared
        guard st.chatEnabled else { return fail(.disabled) }
        let kind = st.chatProviderKind
        guard Self.supportsTools(kind) else {
            return fail(.notConfigured("This provider can't use storage tools. Pick Gemini or an OpenAI-style one."))
        }
        var key = ""
        if kind.needsKey {
            switch Self.loadKey(kind) {
            case .success(let k): key = k
            case .failure(let e): return fail(e)
            }
        }
        let model = st.chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty { return fail(.notConfigured("Pick a model in Chat settings.")) }
        var base = st.chatBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }

        var headers = ["Content-Type": "application/json"]
        let url: URL?
        var body: [String: Any]
        if kind == .gemini {
            let safe = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(safe):generateContent")
            headers["x-goog-api-key"] = key
            body = ["systemInstruction": ["parts": [["text": system]]],
                    "contents": session.raw,
                    "tools": [["functionDeclarations": StashTools.geminiDeclarations()]]]
        } else {
            url = base.isEmpty ? nil : URL(string: base + "/chat/completions")
            if !key.isEmpty { headers["Authorization"] = "Bearer " + key }
            var msgs: [[String: Any]] = [["role": "system", "content": system]]
            msgs += session.raw
            body = ["model": model, "messages": msgs, "tools": StashTools.openAITools()]
        }
        guard let u = url, u.scheme == "http" || u.scheme == "https",
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            return fail(.notConfigured("The server address in Chat settings isn't valid."))
        }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.httpBody = data
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        cancel()
        let t = self.session.dataTask(with: req) { [weak self] data, response, error in
            let decoded = Self.decode(kind: kind, data: data, response: response, error: error)
            DispatchQueue.main.async {
                if (error as? URLError)?.code == .cancelled { return }
                self?.task = nil
                switch decoded {
                case .failure(let e): completion(.failure(e))
                case .success(let obj): completion(Self.readStep(kind: kind, obj: obj, session: session))
                }
            }
        }
        task = t
        t.resume()
    }

    /// Asks the model again and again until it answers in plain text, running each tool it
    /// requests (at most `maxRounds` rounds). `execute` must call its reply closure exactly once,
    /// on the main thread, so a confirm sheet can wait for the user.
    func runTools(_ session: ToolSession, system: String, maxRounds: Int = 6,
                  execute: @escaping (ToolCall, @escaping (String) -> Void) -> Void,
                  completion: @escaping (Result<String, ChatError>) -> Void) {
        func round(_ n: Int) {
            step(session, system: system) { result in
                switch result {
                case .failure(let e):
                    completion(.failure(e))
                case .success(.text(let t)):
                    completion(.success(t))
                case .success(.calls(let calls)):
                    if n >= maxRounds {
                        completion(.failure(.notConfigured("I kept going round in circles. Try asking again.")))
                        return
                    }
                    var done: [(ToolCall, String)] = []
                    func next(_ i: Int) {
                        if i == calls.count {
                            session.addResults(done)
                            round(n + 1)
                            return
                        }
                        execute(calls[i]) { out in
                            done.append((calls[i], out))
                            next(i + 1)
                        }
                    }
                    next(0)
                }
            }
        }
        round(0)
    }

    private static func readStep(kind: ChatProviderKind, obj: [String: Any], session: ToolSession) -> Result<ToolStep, ChatError> {
        if kind == .gemini {
            guard let cands = obj["candidates"] as? [[String: Any]], let first = cands.first,
                  var content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                return .failure(obj["promptFeedback"] != nil ? .blocked : .badResponse)
            }
            if content["role"] == nil { content["role"] = "model" }
            session.raw.append(content)
            let calls = parts.enumerated().compactMap { (i, p) -> ToolCall? in
                guard let fc = p["functionCall"] as? [String: Any], let n = fc["name"] as? String else { return nil }
                return ToolCall(id: "g\(i)", name: n, args: fc["args"] as? [String: Any] ?? [:])
            }
            if !calls.isEmpty { return .success(.calls(calls)) }
            let text = parts.compactMap { $0["text"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .failure(.badResponse) : .success(.text(text))
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else { return .failure(.badResponse) }
        let content = (msg["content"] as? String) ?? ""
        if let tcs = msg["tool_calls"] as? [[String: Any]], !tcs.isEmpty {
            // Keep only the fields every OpenAI-style server accepts when the message is sent back.
            session.raw.append(["role": "assistant", "content": content, "tool_calls": tcs])
            let calls = tcs.enumerated().compactMap { (i, tc) -> ToolCall? in
                guard let fn = tc["function"] as? [String: Any], let n = fn["name"] as? String else { return nil }
                var args: [String: Any] = [:]
                if let s = fn["arguments"] as? String, let d = s.data(using: .utf8),
                   let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { args = o }
                return ToolCall(id: (tc["id"] as? String) ?? "call\(i)", name: n, args: args)
            }
            if !calls.isEmpty { return .success(.calls(calls)) }
        }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { session.raw.append(["role": "assistant", "content": text]) }
        return text.isEmpty ? .failure(.badResponse) : .success(.text(text))
    }

    /// Model names the provider offers (best guess first). Calls back on the main thread; an empty
    /// list means "couldn't find out".
    func listModels(kind: ChatProviderKind, completion: @escaping ([String]) -> Void) {
        let st = Settings.shared
        var base = st.chatBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let key = (try? KeychainStore.read(account: kind.keyAccount)) ?? ""

        let urlString: String
        switch kind {
        case .gemini: urlString = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200"
        case .openAICompatible, .nvidia: urlString = base + "/models"
        case .ollama: urlString = base + "/api/tags"
        }
        guard let url = URL(string: urlString) else { DispatchQueue.main.async { completion([]) }; return }
        var req = URLRequest(url: url)
        if kind == .gemini { req.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        if kind.isOpenAIStyle, !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }

        session.dataTask(with: req) { data, _, _ in
            var names: [String] = []
            if let data = data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                switch kind {
                case .gemini:
                    for m in (obj["models"] as? [[String: Any]]) ?? [] {
                        guard let n = m["name"] as? String,
                              let methods = m["supportedGenerationMethods"] as? [String],
                              methods.contains("generateContent") else { continue }
                        names.append(n.hasPrefix("models/") ? String(n.dropFirst(7)) : n)
                    }
                    names = Self.rankGemini(names)
                case .openAICompatible, .nvidia:
                    names = ((obj["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
                case .ollama:
                    names = ((obj["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
                }
            }
            DispatchQueue.main.async { completion(names) }
        }.resume()
    }

    /// Prefer plain, stable "flash" chat models, newest first; keep the rest after them.
    private static func rankGemini(_ names: [String]) -> [String] {
        let skip = ["image", "tts", "audio", "live", "embedding", "robotics", "computer", "vision", "learnlm", "aqa"]
        let usable = names.filter { n in !skip.contains(where: { n.contains($0) }) }
        func score(_ n: String) -> Int {
            var s = 0
            if n.contains("flash") { s += 4 }
            if n.contains("lite") { s -= 1 }
            if n.contains("preview") || n.contains("exp") { s -= 2 }
            if n.hasPrefix("gemini-") { s += 1 }
            return s
        }
        return usable.sorted { a, b in
            let sa = score(a), sb = score(b)
            return sa != sb ? sa > sb : a > b
        }
    }

    private func finish(_ r: Result<String, ChatError>, _ completion: @escaping (Result<String, ChatError>) -> Void) {
        DispatchQueue.main.async { completion(r) }
    }

    // MARK: Requests

    private static func makeRequest(kind: ChatProviderKind, model: String, baseURL: String,
                                    key: String, system: String, messages: [ChatMessage]) -> URLRequest? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }

        let url: URL?
        var body: [String: Any]
        var headers: [String: String] = ["Content-Type": "application/json"]

        switch kind {
        case .gemini:
            let safe = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(safe):generateContent")
            headers["x-goog-api-key"] = key      // in a header, so it never appears in a URL
            body = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": messages.map { m -> [String: Any] in
                    ["role": m.role == .assistant ? "model" : "user", "parts": [["text": m.text]]]
                }
            ]
        case .openAICompatible, .nvidia:
            url = base.isEmpty ? nil : URL(string: base + "/chat/completions")
            if !key.isEmpty { headers["Authorization"] = "Bearer " + key }
            body = ["model": model, "messages": chatArray(system: system, messages: messages)]
        case .ollama:
            url = base.isEmpty ? nil : URL(string: base + "/api/chat")
            body = ["model": model, "stream": false, "messages": chatArray(system: system, messages: messages)]
        }

        guard let u = url, u.scheme == "http" || u.scheme == "https",
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.httpBody = data
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    private static func chatArray(system: String, messages: [ChatMessage]) -> [[String: String]] {
        var out: [[String: String]] = [["role": "system", "content": system]]
        for m in messages {
            out.append(["role": m.role == .assistant ? "assistant" : "user", "content": m.text])
        }
        return out
    }

    // MARK: Responses

    /// Network and HTTP errors turned into ChatError; on success, the reply body as a JSON object.
    private static func decode(kind: ChatProviderKind, data: Data?, response: URLResponse?,
                               error: Error?) -> Result<[String: Any], ChatError> {
        if let e = error as? URLError {
            switch e.code {
            case .cancelled: return .failure(.timedOut)
            case .timedOut: return .failure(.timedOut)
            case .cannotConnectToHost, .cannotFindHost:
                return .failure(kind == .ollama ? .ollamaNotRunning : .noInternet)
            case .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed, .dataNotAllowed:
                return .failure(.noInternet)
            default: return .failure(.noInternet)
            }
        } else if error != nil {
            return .failure(.badResponse)
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.badResponse) }

        switch http.statusCode {
        case 200..<300: break
        case 400:
            // Gemini reports a bad key as 400 "API key not valid".
            if let text = errorText(data), text.lowercased().contains("api key") { return .failure(.unauthorized) }
            return .failure(.badResponse)
        case 401, 403: return .failure(.unauthorized)
        case 404: return .failure(.modelNotFound)
        case 429:
            let secs = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0) }
            return .failure(.rateLimited(secs))
        default: return .failure(.server(http.statusCode))
        }

        guard let data = data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.badResponse)
        }
        return .success(obj)
    }

    private static func parse(kind: ChatProviderKind, data: Data?, response: URLResponse?, error: Error?) -> Result<String, ChatError> {
        let obj: [String: Any]
        switch decode(kind: kind, data: data, response: response, error: error) {
        case .failure(let e): return .failure(e)
        case .success(let o): obj = o
        }
        var text: String?
        switch kind {
        case .gemini:
            if let cands = obj["candidates"] as? [[String: Any]], let first = cands.first,
               let content = first["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined()
            } else if obj["promptFeedback"] != nil {
                return .failure(.blocked)
            }
        case .openAICompatible, .nvidia:
            if let choices = obj["choices"] as? [[String: Any]], let first = choices.first,
               let msg = first["message"] as? [String: Any] {
                text = msg["content"] as? String
            }
        case .ollama:
            if let msg = obj["message"] as? [String: Any] { text = msg["content"] as? String }
        }
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .failure(.badResponse) : .success(trimmed)
    }

    private static func errorText(_ data: Data?) -> String? {
        guard let data = data,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let err = obj["error"] as? [String: Any] else { return nil }
        return err["message"] as? String
    }
}
