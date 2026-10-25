import AppKit
import Foundation
import os

/// One small log: Console (subsystem com.yash.mooncat) and ~/Library/Logs/MoonCat/mooncat.log,
/// rotated at 1 MB. Never pass API keys or message text to it.
enum Log {
    private static let logger = Logger(subsystem: "com.yash.mooncat", category: "app")
    private static let queue = DispatchQueue(label: "com.yash.mooncat.log")
    private static let maxBytes = 1_048_576

    static var fileURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Library/Logs/MoonCat/mooncat.log")
    }

    static func info(_ message: String) {
        let m = sanitize(message)
        logger.info("\(m, privacy: .public)")
        write("INFO", m)
    }

    static func error(_ message: String) {
        let m = sanitize(message)
        logger.error("\(m, privacy: .public)")
        write("ERROR", m)
    }

    static func revealInFinder() {
        queue.async {
            let url = fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    /// Defence in depth: blank out anything that looks like a key or token.
    private static func sanitize(_ input: String) -> String {
        var out = input
        let patterns = ["(?i)(bearer\\s+)[A-Za-z0-9._~+/=-]+",
                        "(?i)(api[_-]?key\\s*[:=]\\s*)[^\\s,;]+",
                        "(?i)(token\\s*[:=]\\s*)[^\\s,;]+",
                        "AIza[0-9A-Za-z_-]{20,}",
                        "gsk_[0-9A-Za-z]{20,}",
                        "sk-[0-9A-Za-z_-]{20,}"]
        for (i, p) in patterns.enumerated() {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: i < 3 ? "$1[hidden]" : "[hidden]")
        }
        return out
    }

    private static let stamp: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func write(_ level: String, _ message: String) {
        queue.async {
            let url = fileURL
            let dir = url.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? NSNumber, size.intValue > maxBytes {
                    let old = dir.appendingPathComponent("mooncat.log.1")
                    try? FileManager.default.removeItem(at: old)
                    try? FileManager.default.moveItem(at: url, to: old)
                }
                let line = "\(stamp.string(from: Date())) [\(level)] \(message)\n"
                let data = Data(line.utf8)
                if FileManager.default.fileExists(atPath: url.path) {
                    let h = try FileHandle(forWritingTo: url)
                    defer { try? h.close() }
                    h.seekToEndOfFile()
                    h.write(data)
                } else {
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                logger.error("Could not write the log file")
            }
        }
    }
}
