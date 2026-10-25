import Foundation
import CryptoKit

enum StashCryptoError: LocalizedError {
    case vault(String)
    case encryptionFailed
    case decryptionFailed
    case tooLarge
    case foldersNotSupported
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .vault(let message):
            return message
        case .encryptionFailed:
            return "I couldn't lock that file."
        case .decryptionFailed:
            return "I couldn't unlock that file. Check your MoonCat password, and that vault.json is still next to the Treasure Box."
        case .tooLarge:
            return "That file is too big to lock (the limit is 1 GB)."
        case .foldersNotSupported:
            return "Folders can't be locked. Compress the folder into a zip first, then lock the zip."
        case .missingFile(let name):
            return "I can't find the stored copy of “\(name)”."
        }
    }
}

/// AES-GCM encryption for "private" Treasure Box items. The key comes from the MoonCat password
/// vault (see Vault.swift); the first time something needs it, MoonCat asks you to create the password.
enum StashCrypto {
    static let maxBytes: Int64 = 1_000_000_000

    static func loadOrCreateKey() throws -> SymmetricKey {
        do {
            return try Vault.shared.masterKey()
        } catch {
            throw StashCryptoError.vault(error.localizedDescription)
        }
    }

    private static func checkSize(_ url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size > maxBytes { throw StashCryptoError.tooLarge }
    }

    /// Reads `source`, writes the AES-GCM sealed bytes to `dest`.
    static func seal(fileAt source: URL, to dest: URL) throws {
        try checkSize(source)
        let key = try loadOrCreateKey()
        let data = try Data(contentsOf: source)
        let box = try AES.GCM.seal(data, using: key)
        guard let combined = box.combined else { throw StashCryptoError.encryptionFailed }
        try combined.write(to: dest, options: .atomic)
    }

    /// Reads sealed bytes from `source`, writes the original file to `dest`.
    static func open(fileAt source: URL, to dest: URL) throws {
        let key = try loadOrCreateKey()
        let data = try Data(contentsOf: source)
        guard let box = try? AES.GCM.SealedBox(combined: data) else { throw StashCryptoError.decryptionFailed }
        let plain: Data
        do {
            plain = try AES.GCM.open(box, using: key)
        } catch {
            throw StashCryptoError.decryptionFailed
        }
        try plain.write(to: dest, options: .atomic)
    }
}

/// Short-lived decrypted copies. Each open gets its own folder, removed after a delay,
/// when MoonCat quits, and at the next launch (in case it crashed).
enum StashTemp {
    static var base: URL {
        return FileManager.default.temporaryDirectory.appendingPathComponent("MoonCatOpen", isDirectory: true)
    }

    static func makeDir() throws -> URL {
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    static func scheduleDeletion(of dir: URL, after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    static func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }
}
