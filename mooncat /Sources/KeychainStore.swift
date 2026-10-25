import Foundation

/// Where chat API keys are kept. The name is historical: nothing here touches the Keychain any more.
/// Keys live encrypted in the MoonCat password vault (Vault.swift), never in UserDefaults.
enum KeychainStore {
    enum KeychainError: Error { case invalidEncoding }

    static func save(_ value: String, account: String) throws {
        try Vault.shared.setSecret(value, account: account)
    }

    /// nil when nothing is saved. Asks for the MoonCat password only if a key is saved and the vault is locked.
    static func read(account: String) throws -> String? {
        return try Vault.shared.secret(account)
    }

    /// Answers without asking for the password.
    static func exists(account: String) -> Bool {
        return Vault.shared.hasSecret(account)
    }

    static func delete(account: String) throws {
        try Vault.shared.removeSecret(account)
    }
}
