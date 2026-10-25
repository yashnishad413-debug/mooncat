import Foundation

enum ChatProviderKind: String, CaseIterable {
    case gemini, openAICompatible, ollama, nvidia

    var title: String {
        switch self {
        case .gemini: return "Google Gemini (free key)"
        case .openAICompatible: return "OpenAI-style (Groq, OpenRouter…)"
        case .ollama: return "Ollama (on this Mac, no key)"
        case .nvidia: return "NVIDIA NIM (free key)"
        }
    }

    /// Speaks the OpenAI chat-completions format (Bearer key, /chat/completions, /models).
    var isOpenAIStyle: Bool { return self == .openAICompatible || self == .nvidia }

    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-2.5-flash"
        case .openAICompatible: return "llama-3.3-70b-versatile"
        case .ollama: return "llama3.2"
        case .nvidia: return "openai/gpt-oss-20b"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .gemini: return ""
        case .openAICompatible: return "https://api.groq.com/openai/v1"
        case .ollama: return "http://localhost:11434"
        case .nvidia: return "https://integrate.api.nvidia.com/v1"
        }
    }

    var needsKey: Bool { return self != .ollama }
    var usesBaseURL: Bool { return self != .gemini }

    /// One saved key per provider, so switching never sends one service's key to another.
    var keyAccount: String { return "chat-key-" + rawValue }

    var keyHint: String {
        switch self {
        case .gemini: return "Free key: aistudio.google.com ▸ Get API key."
        case .openAICompatible: return "Groq: console.groq.com ▸ API keys. OpenRouter: openrouter.ai/keys (pick a model ending in :free)."
        case .ollama: return "Install Ollama, run `ollama pull llama3.2`, and keep it running. Nothing leaves your Mac."
        case .nvidia: return "Free key: build.nvidia.com ▸ sign in ▸ Settings ▸ API Keys (phone check once, about 40 requests/min). Use Find models to pick one."
        }
    }
}

extension Settings {
    /// Chat is OFF by default. While off, MoonCat makes no network calls for chat at all.
    var chatEnabled: Bool {
        get { return UserDefaults.standard.bool(forKey: "chatEnabled") }
        set { storeExtra(newValue, "chatEnabled") }
    }
    var chatProviderKind: ChatProviderKind {
        get { return ChatProviderKind(rawValue: UserDefaults.standard.string(forKey: "chatProvider") ?? "") ?? .gemini }
        set { storeExtra(newValue.rawValue, "chatProvider") }
    }
    var chatModel: String {
        get {
            let s = UserDefaults.standard.string(forKey: "chatModel") ?? ""
            return s.isEmpty ? chatProviderKind.defaultModel : s
        }
        set { storeExtra(newValue, "chatModel") }
    }
    var chatBaseURL: String {
        get {
            let s = UserDefaults.standard.string(forKey: "chatBaseURL") ?? ""
            return s.isEmpty ? chatProviderKind.defaultBaseURL : s
        }
        set { storeExtra(newValue, "chatBaseURL") }
    }
    /// How many earlier messages are sent along with a new one.
    var chatHistoryCount: Int {
        get { return UserDefaults.standard.integer(forKey: "chatHistoryCount") }
        set { storeExtra(newValue, "chatHistoryCount") }
    }
    /// Lets Moon see and change the Treasure Box through tools. Off until the user ticks it.
    var chatStorageAccess: Bool {
        get { return UserDefaults.standard.bool(forKey: "chatStorageAccess") }
        set { storeExtra(newValue, "chatStorageAccess") }
    }
    var chatPersonality: String {
        get { return UserDefaults.standard.string(forKey: "chatPersonality") ?? Settings.defaultPersonality }
        set { storeExtra(newValue, "chatPersonality") }
    }

    static let defaultPersonality = "You are Moon, a small, sleepy, affectionate cat who lives on the user's desktop. Reply in one to three short sentences. You may say 'mrrp' or 'purr' now and then. Never claim you can see their screen or files. If they ask for real help, give it briefly and plainly."

    static let chatDefaults: [String: Any] = [
        "chatEnabled": false,
        "chatProvider": ChatProviderKind.gemini.rawValue,
        "chatHistoryCount": 10
    ]
}
