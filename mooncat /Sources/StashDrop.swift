import AppKit

/// Turns whatever was dropped or pasted into real files the Treasure Box can store:
/// real files pass through; images become .png, web links become .webloc, text becomes .txt or .md.
/// Files made here live in a temporary folder; call `cleanup(_:)` once they have been stored.
enum StashDrop {
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .png, .tiff, .string]

    private static var tempRoot: URL {
        return FileManager.default.temporaryDirectory.appendingPathComponent("MoonCatDrop", isDirectory: true)
    }

    static func files(from pasteboard: NSPasteboard) -> [URL] {
        // 1. Real files and folders.
        if let objs = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL], !objs.isEmpty {
            return objs
        }

        let fm = FileManager.default
        let dir = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return []
        }

        var made: [URL] = []

        // 2. An image.
        if let png = imagePNGData(from: pasteboard) {
            let url = uniqueURL(in: dir, name: "Pasted Image \(stamp()).png")
            if (try? png.write(to: url)) != nil { made.append(url) }
        }

        // 3. Web links.
        if made.isEmpty,
           let links = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for link in links where !link.isFileURL && !link.absoluteString.isEmpty {
                let base = sanitize(link.host ?? "Link")
                let url = uniqueURL(in: dir, name: base + ".webloc")
                let plist: [String: Any] = ["URL": link.absoluteString]
                if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                   (try? data.write(to: url)) != nil {
                    made.append(url)
                }
            }
        }

        // 4. Plain text.
        if made.isEmpty, let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let ext = looksLikeMarkdown(text) ? "md" : "txt"
            let url = uniqueURL(in: dir, name: "Pasted Text \(stamp()).\(ext)")
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { made.append(url) }
        }

        if made.isEmpty { try? fm.removeItem(at: dir) }
        return made
    }

    /// Removes any temporary files this type created (real files are never touched).
    static func cleanup(_ urls: [URL]) {
        let rootPath = tempRoot.path
        for u in urls where u.path.hasPrefix(rootPath) {
            try? FileManager.default.removeItem(at: u.deletingLastPathComponent())
        }
    }

    // MARK: Helpers

    private static func imagePNGData(from pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    private static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Link" : String(trimmed.prefix(60))
    }

    private static func looksLikeMarkdown(_ text: String) -> Bool {
        let patterns = ["(?m)^#{1,6}\\s+\\S", "(?m)^[*-]\\s+\\S", "\\[[^\\]]+\\]\\([^)]+\\)", "(?m)^```"]
        for p in patterns where text.range(of: p, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}
