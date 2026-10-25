import AppKit
import CryptoKit

/// Cleanup ideas for the Treasure Box. Nothing is deleted until the user ticks items and confirms.
/// Locked (private) items are never looked at.
struct CleanupSuggestions {
    /// Each group holds identical files; the first (oldest stored) is the one to keep.
    var duplicates: [[StashItem]]
    /// Files not touched for a while, excluding the extra copies already listed as duplicates.
    var old: [StashItem]
}

enum StashCleanup {
    static let oldDays = 90

    /// Hashing can take a while, so it runs off the main thread. `completion` is called on the main thread.
    static func find(completion: @escaping (CleanupSuggestions) -> Void) {
        let st = Stash.shared
        let files = st.items.filter { !$0.isFolder && !$0.isPrivate }
        var urls: [String: URL] = [:]
        for f in files { urls[f.id] = st.url(for: f) }
        let stale = st.staleItems(olderThanDays: oldDays).filter { !$0.isPrivate }

        DispatchQueue.global(qos: .utility).async {
            var bySize: [Int64: [StashItem]] = [:]
            for f in files where f.size > 0 { bySize[f.size, default: []].append(f) }
            var groups: [[StashItem]] = []
            for (_, same) in bySize where same.count > 1 {
                var byHash: [String: [StashItem]] = [:]
                for f in same {
                    if let u = urls[f.id], let h = hash(of: u) { byHash[h, default: []].append(f) }
                }
                for (_, g) in byHash where g.count > 1 { groups.append(g.sorted { $0.date < $1.date }) }
            }
            groups.sort { $0[0].size > $1[0].size }
            let extras = Set(groups.flatMap { $0.dropFirst().map { $0.id } })
            let old = stale.filter { !extras.contains($0.id) }.sorted { $0.size > $1.size }
            DispatchQueue.main.async { completion(CleanupSuggestions(duplicates: groups, old: old)) }
        }
    }

    private static func hash(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        while true {
            let more: Bool = autoreleasepool {
                guard let d = try? h.read(upToCount: 1 << 20), !d.isEmpty else { return false }
                sha.update(data: d)
                return true
            }
            if !more { break }
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { return true }
}

enum StashCleanupUI {
    private static let maxRows = 40

    static func present(on window: NSWindow) {
        StashCleanup.find { show($0, on: window) }
    }

    private static func size(_ n: Int64) -> String { return ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private static func show(_ s: CleanupSuggestions, on window: NSWindow) {
        let alert = NSAlert()
        var rows: [(id: String, title: String, ticked: Bool)] = []
        for g in s.duplicates {
            for it in g.dropFirst() {
                rows.append((it.id, "Copy of “\(g[0].name)”: \(it.name) (\(size(it.size)))", true))
            }
        }
        for it in s.old {
            let age = DateFormatter.localizedString(from: it.date, dateStyle: .medium, timeStyle: .none)
            rows.append((it.id, "Old: \(it.name) (\(size(it.size)), stored \(age))", false))
        }
        if rows.isEmpty {
            alert.messageText = "Nothing to tidy"
            alert.informativeText = "No identical files, and nothing older than \(StashCleanup.oldDays) days."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window, completionHandler: nil)
            return
        }
        let shownRows = Array(rows.prefix(maxRows))
        let rowH: CGFloat = 22
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: 470, height: max(240, CGFloat(shownRows.count) * rowH + 8)))
        var boxes: [NSButton] = []
        for (i, r) in shownRows.enumerated() {
            let b = NSButton(checkboxWithTitle: r.title, target: nil, action: nil)
            b.identifier = NSUserInterfaceItemIdentifier(r.id)
            b.state = r.ticked ? .on : .off
            b.lineBreakMode = .byTruncatingMiddle
            b.frame = NSRect(x: 6, y: 4 + CGFloat(i) * rowH, width: 458, height: 20)
            doc.addSubview(b)
            boxes.append(b)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 470, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = doc

        alert.messageText = "Tidy up the Treasure Box"
        let more = rows.count > maxRows ? " Showing the first \(maxRows) of \(rows.count); run it again for the rest." : ""
        alert.informativeText = "Ticked items are deleted for good. Identical copies are ticked (the oldest copy stays). Old files are not ticked, so choose what you want gone." + more
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Delete Ticked")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let items = boxes.filter { $0.state == .on }
                .compactMap { $0.identifier.flatMap { Stash.shared.item($0.rawValue) } }
            Stash.shared.removeMany(items)
        }
    }
}
