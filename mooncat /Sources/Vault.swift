import AppKit
import CryptoKit
import CommonCrypto
import Security

enum VaultError: LocalizedError {
    case cancelled
    case weakPassword(String)
    case damaged
    case legacyKey(OSStatus)
    case failed

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "That needs your MoonCat password."
        case .weakPassword(let m):
            return m
        case .damaged:
            return "The password file (vault.json) can't be read. I won't touch it. Restore it from a backup."
        case .legacyKey:
            return "I need the old Keychain key once, so your locked files stay readable. Try again and choose Allow."
        case .failed:
            return "I couldn't use the password file."
        }
    }
}

/// MoonCat's own password system. It does not use the Keychain.
///
/// A random 256-bit master key encrypts locked files and chat API keys. The master key is itself
/// encrypted ("wrapped") with a key made from your password (PBKDF2, 200,000 rounds) and stored in
/// `vault.json` next to the Treasure Box index. Changing the password only re-wraps the master key,
/// so no locked file has to be re-encrypted. There is no recovery: forget the password and the
/// locked files and saved keys are gone. Keep `vault.json` with the Treasure Box folder.
///
/// Used from the main thread (it shows password sheets).
final class Vault {
    static let shared = Vault()

    private struct VaultFile: Codable {
        var version = 1
        var rounds: Int
        var salt: Data
        var wrappedKey: Data
        var secrets: [String: Data]
    }

    private static let rounds = 200_000
    private static let minLength = 8

    private let url: URL
    private var file: VaultFile?
    private var damaged = false
    private var master: SymmetricKey?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("MoonCat/Stash", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("vault.json")
        if FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(VaultFile.self, from: data) {
                file = f
            } else {
                damaged = true
            }
        }
    }

    var isSetUp: Bool { return file != nil }

    // MARK: Master key

    /// The master key. Asks for the password when needed: creates one the first time, otherwise
    /// asks for it once per launch.
    func masterKey() throws -> SymmetricKey {
        if let m = master { return m }
        if Thread.isMainThread { return try promptForKey() }
        return try DispatchQueue.main.sync { try self.promptForKey() }
    }

    private func promptForKey() throws -> SymmetricKey {
        if let m = master { return m }
        if damaged { throw VaultError.damaged }
        var message: String? = nil
        if file == nil {
            while true {
                guard let pw = VaultPrompts.create(message: message) else { throw VaultError.cancelled }
                do {
                    try create(password: pw)
                    if let m = master { return m }
                    throw VaultError.failed
                } catch VaultError.weakPassword(let m) {
                    message = m
                }
            }
        }
        while true {
            guard let pw = VaultPrompts.enter(message: message) else { throw VaultError.cancelled }
            if unlock(pw) { if let m = master { return m } }
            message = "That isn't the right password."
        }
    }

    private func create(password: String) throws {
        guard password.count >= Vault.minLength else {
            throw VaultError.weakPassword("Use at least \(Vault.minLength) characters.")
        }
        // Keep the key that already protects locked files (one last Keychain read), so none of
        // them need re-encrypting. With nothing to carry over, start with a fresh random key.
        let key: SymmetricKey
        switch Vault.readLegacyKey() {
        case .found(let d): key = SymmetricKey(data: d)
        case .missing: key = SymmetricKey(size: .bits256)
        case .failed(let s): throw VaultError.legacyKey(s)
        }
        let salt = Vault.randomBytes(16)
        guard let kek = Vault.derive(password, salt: salt, rounds: Vault.rounds),
              let wrapped = try? AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: kek).combined else {
            throw VaultError.failed
        }
        let f = VaultFile(rounds: Vault.rounds, salt: salt, wrappedKey: wrapped, secrets: [:])
        try write(f)
        // Check what was written really opens before anything old is removed.
        guard let back = try? Data(contentsOf: url), let again = try? JSONDecoder().decode(VaultFile.self, from: back),
              Vault.unwrap(again, password: password) != nil else { throw VaultError.failed }
        file = again
        master = key
        Vault.deleteLegacy()
    }

    /// True (and unlocked) when the password is right.
    func unlock(_ password: String) -> Bool {
        guard let f = file, let key = Vault.unwrap(f, password: password) else { return false }
        master = key
        return true
    }

    // MARK: Change password

    /// Asks for the old password, then the new one twice.
    func changePasswordInteractive() {
        NSApp.activate(ignoringOtherApps: true)
        guard isSetUp else {
            let a = NSAlert()
            a.messageText = "No password yet"
            a.informativeText = "MoonCat will ask you to create one the first time you lock a file or save a chat key."
            a.runModal()
            return
        }
        var message: String? = nil
        while let (old, new) = VaultPrompts.change(message: message) {
            do {
                try changePassword(old: old, new: new)
                let a = NSAlert()
                a.messageText = "Password changed"
                a.informativeText = "Use the new one from now on. It can't be recovered if you forget it."
                a.runModal()
                return
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func changePassword(old: String, new: String) throws {
        guard let f = file, let key = Vault.unwrap(f, password: old) else {
            throw VaultError.weakPassword("The current password isn't right.")
        }
        guard new.count >= Vault.minLength else {
            throw VaultError.weakPassword("Use at least \(Vault.minLength) characters.")
        }
        let salt = Vault.randomBytes(16)
        guard let kek = Vault.derive(new, salt: salt, rounds: Vault.rounds),
              let wrapped = try? AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: kek).combined else {
            throw VaultError.failed
        }
        var g = f
        g.rounds = Vault.rounds
        g.salt = salt
        g.wrappedKey = wrapped
        try write(g)
        file = g
        master = key
    }

    // MARK: Saved secrets (chat API keys)

    func hasSecret(_ account: String) -> Bool { return file?.secrets[account] != nil }

    /// nil when nothing is saved under `account` (no password needed to find that out).
    func secret(_ account: String) throws -> String? {
        guard let blob = file?.secrets[account] else { return nil }
        let key = try masterKey()
        guard let box = try? AES.GCM.SealedBox(combined: blob),
              let plain = try? AES.GCM.open(box, using: key),
              let s = String(data: plain, encoding: .utf8) else { throw VaultError.failed }
        return s
    }

    func setSecret(_ value: String, account: String) throws {
        let key = try masterKey()
        guard var f = file else { throw VaultError.failed }
        guard let sealed = try? AES.GCM.seal(Data(value.utf8), using: key).combined else { throw VaultError.failed }
        f.secrets[account] = sealed
        try write(f)
        file = f
    }

    func removeSecret(_ account: String) throws {
        guard var f = file, f.secrets[account] != nil else { return }
        f.secrets[account] = nil
        try write(f)
        file = f
    }

    // MARK: Storage and crypto helpers

    private func write(_ f: VaultFile) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(f)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func unwrap(_ f: VaultFile, password: String) -> SymmetricKey? {
        guard let kek = derive(password, salt: f.salt, rounds: f.rounds),
              let box = try? AES.GCM.SealedBox(combined: f.wrappedKey),
              let raw = try? AES.GCM.open(box, using: kek), raw.count == 32 else { return nil }
        return SymmetricKey(data: raw)
    }

    private static func derive(_ password: String, salt: Data, rounds: Int) -> SymmetricKey? {
        let saltBytes = [UInt8](salt)
        var out = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                                          saltBytes, saltBytes.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                          UInt32(rounds), &out, out.count)
        return status == Int32(kCCSuccess) ? SymmetricKey(data: Data(out)) : nil
    }

    private static func randomBytes(_ n: Int) -> Data {
        return SymmetricKey(size: SymmetricKeySize(bitCount: n * 8)).withUnsafeBytes { Data($0) }
    }

    // MARK: Old Keychain entries (read once, then removed)

    private enum Legacy { case found(Data), missing, failed(OSStatus) }

    private static let legacyService = "com.yash.mooncat"

    private static func legacyQuery(_ account: String) -> [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: account]
    }

    private static func readLegacyKey() -> Legacy {
        var q = legacyQuery("stash-key")
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let d = result as? Data, d.count == 32 else { return .failed(status) }
        return .found(d)
    }

    /// Best effort. Saved chat keys are not carried over; paste them again once.
    private static func deleteLegacy() {
        var accounts = ["stash-key"]
        accounts += ChatProviderKind.allCases.map { $0.keyAccount }
        for a in accounts { SecItemDelete(legacyQuery(a) as CFDictionary) }
    }
}

// MARK: - Password sheets

enum VaultPrompts {
    private static func fields(_ labels: [String]) -> (NSView, [NSSecureTextField]) {
        let rowH: CGFloat = 30
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: CGFloat(labels.count) * rowH))
        var out: [NSSecureTextField] = []
        for (i, l) in labels.enumerated() {
            let y = CGFloat(labels.count - 1 - i) * rowH
            let label = NSTextField(labelWithString: l)
            label.frame = NSRect(x: 0, y: y + 4, width: 110, height: 18)
            let f = NSSecureTextField(frame: NSRect(x: 114, y: y + 2, width: 186, height: 22))
            view.addSubview(label)
            view.addSubview(f)
            out.append(f)
        }
        return (view, out)
    }

    private static func ask(title: String, text: String, labels: [String], button: String) -> [String]? {
        NSApp.activate(ignoringOtherApps: true)
        let (view, boxes) = fields(labels)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.accessoryView = view
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        a.layout()
        a.window.initialFirstResponder = boxes[0]
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return boxes.map { $0.stringValue }
    }

    /// Returns the new password, or nil if cancelled. `message` shows what was wrong last time.
    static func create(message: String?) -> String? {
        var note = message
        while true {
            let text = (note.map { $0 + "\n\n" } ?? "")
                + "It protects your locked files and saved chat keys. It can't be recovered: if you forget it, those are gone."
            guard let v = ask(title: "Create your MoonCat password", text: text,
                              labels: ["Password", "Again"], button: "Create") else { return nil }
            if v[0] != v[1] { note = "The two passwords don't match."; continue }
            return v[0]
        }
    }

    static func enter(message: String?) -> String? {
        let text = message ?? "Your locked files and saved chat keys are protected by it."
        return ask(title: "Enter your MoonCat password", text: text, labels: ["Password"], button: "Unlock")?.first
    }

    static func change(message: String?) -> (String, String)? {
        let text = message ?? "You need your current password. There is no way to reset it without it."
        guard let v = ask(title: "Change MoonCat password", text: text,
                          labels: ["Current", "New", "New again"], button: "Change") else { return nil }
        if v[1] != v[2] { return change(message: "The two new passwords don't match.") }
        return (v[0], v[1])
    }
}
