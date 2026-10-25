import AppKit

// MARK: - Treasure Box storage

struct StashItem: Codable {
    var id: String
    var name: String
    var size: Int64
    var date: Date
    var originalPath: String
    var isFolder: Bool
    var tags: [String] = []
    var note: String = ""
    /// Private items are stored AES-GCM encrypted (see Crypto.swift) and only decrypted to a temp copy when opened.
    var isPrivate: Bool = false
    /// Id of the folder this item sits in; nil means the top level of the box.
    var parentID: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, size, date, originalPath, isFolder, tags, note, isPrivate, parentID
    }
}

extension StashItem {
    /// Declared in an extension so the memberwise initializer survives.
    /// `tags` and `note` are optional on disk, so index.json files written before they existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        size = try c.decode(Int64.self, forKey: .size)
        date = try c.decode(Date.self, forKey: .date)
        originalPath = try c.decode(String.self, forKey: .originalPath)
        isFolder = try c.decode(Bool.self, forKey: .isFolder)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
    }

    /// nil when the item does not match every word of the query; otherwise a rank where
    /// lower is better (0 name starts with it, 1 name contains it, 2 a tag, 3 the note).
    /// Matching ignores case and accents. An empty query matches everything.
    func matchRank(_ query: String) -> Int? {
        let words = query.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if words.isEmpty { return 0 }
        let loose: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let prefix: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        var rank = 0
        for w in words {
            var best: Int? = nil
            if name.range(of: w, options: prefix) != nil {
                best = 0
            } else if name.range(of: w, options: loose) != nil {
                best = 1
            } else if tags.contains(where: { $0.range(of: w, options: loose) != nil }) {
                best = 2
            } else if note.range(of: w, options: loose) != nil {
                best = 3
            }
            guard let b = best else { return nil }
            rank = max(rank, b)
        }
        return rank
    }

    func matches(_ query: String) -> Bool {
        return matchRank(query) != nil
    }
}

enum StashError: LocalizedError {
    case invalidName, notFound, nameTaken(String), cannotMoveIntoSelf(String)
    var errorDescription: String? {
        switch self {
        case .invalidName: return "That name can't be used. It can't be empty or contain “/”."
        case .notFound: return "I can't find that item or folder any more."
        case .nameTaken(let n): return "Something named “\(n)” is already in this folder."
        case .cannotMoveIntoSelf(let n): return "“\(n)” can't go inside itself."
        }
    }
}

final class Stash {
    static let shared = Stash()
    /// Posted after every change to the index (add, remove, tags/note edit).
    static let didChange = Notification.Name("MoonCatStashDidChange")

    let root: URL
    let indexURL: URL
    private(set) var items: [StashItem] = []

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("MoonCat/Stash", isDirectory: true)
        root = base
        indexURL = base.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
        migrateLegacyFolders()
    }

    /// Set by the Treasure Box window while it asks to store files, so they land in the folder being viewed.
    var importParent: String?

    func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            items = try dec.decode([StashItem].self, from: data)
        } catch {
            // Never lose an index silently: keep a copy of what could not be read
            // before the next save() overwrites it.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = indexURL.deletingLastPathComponent()
                .appendingPathComponent("index.unreadable-\(stamp).json")
            try? data.write(to: backup, options: .atomic)
            items = []
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
        NotificationCenter.default.post(name: Stash.didChange, object: self)
    }

    /// Suffix added to the stored file name of a private (encrypted) item.
    static let sealedSuffix = ".sealed"

    /// Where the item is stored on disk. For a private item this is the ENCRYPTED file:
    /// never hand it to another app; use `openableURL(for:)` instead.
    func url(for item: StashItem) -> URL {
        let file = item.isPrivate ? item.name + Stash.sealedSuffix : item.name
        return root.appendingPathComponent(item.id, isDirectory: true).appendingPathComponent(file)
    }

    /// A URL other apps can open. Plain items return their stored file. Private items are decrypted
    /// into a temporary folder that is deleted after `keepFor` seconds (and when MoonCat quits).
    func openableURL(for item: StashItem, keepFor seconds: TimeInterval = 60) throws -> URL {
        if item.isFolder {
            let dir = try StashTemp.makeDir()
            do {
                let out = try materialize(item, into: dir)
                StashTemp.scheduleDeletion(of: dir, after: seconds)
                return out
            } catch {
                try? FileManager.default.removeItem(at: dir)
                throw error
            }
        }
        let stored = url(for: item)
        guard FileManager.default.fileExists(atPath: stored.path) else {
            throw StashCryptoError.missingFile(item.name)
        }
        guard item.isPrivate else { return stored }
        let dir = try StashTemp.makeDir()
        let out = dir.appendingPathComponent(item.name)
        do {
            try StashCrypto.open(fileAt: stored, to: out)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        StashTemp.scheduleDeletion(of: dir, after: seconds)
        return out
    }

    /// Icon for lists. Private items show the icon for their file type, never the encrypted file's.
    func icon(for item: StashItem) -> NSImage {
        if item.isFolder { return NSImage(named: NSImage.folderName) ?? NSImage() }
        if item.isPrivate {
            return NSWorkspace.shared.icon(forFileType: (item.name as NSString).pathExtension)
        }
        return NSWorkspace.shared.icon(forFile: url(for: item).path)
    }

    /// Locks (encrypts) or unlocks (decrypts) the stored copy of one item.
    func setPrivate(id: String, _ on: Bool) throws {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[i]
        if item.isPrivate == on { return }
        if item.isFolder { throw StashCryptoError.foldersNotSupported }

        let fm = FileManager.default
        let dir = root.appendingPathComponent(item.id, isDirectory: true)
        let plain = dir.appendingPathComponent(item.name)
        let sealed = dir.appendingPathComponent(item.name + Stash.sealedSuffix)
        guard fm.fileExists(atPath: on ? plain.path : sealed.path) else {
            throw StashCryptoError.missingFile(item.name)
        }
        var plainIsDir: ObjCBool = false
        if on, fm.fileExists(atPath: plain.path, isDirectory: &plainIsDir), plainIsDir.boolValue {
            throw StashCryptoError.foldersNotSupported
        }

        if on {
            try StashCrypto.seal(fileAt: plain, to: sealed)
            try fm.removeItem(at: plain)
        } else {
            try StashCrypto.open(fileAt: sealed, to: plain)
            try fm.removeItem(at: sealed)
        }
        items[i].isPrivate = on
        save()
    }

    func totalSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for case let u as URL in en {
                let v = try? u.resourceValues(forKeys: [.fileSizeKey])
                total += Int64(v?.fileSize ?? 0)
            }
        }
        return total
    }

    // Copies the file into the stash. Each file lives in its own folder on disk, so identical
    // names never collide. A real folder becomes a navigable box folder with its contents inside;
    // packages (.app, .pages ...) stay single items.
    @discardableResult
    func add(_ src: URL, moveOriginal: Bool, parent: String? = nil) -> StashItem? {
        guard let created = addTree(src, parent: parent ?? importParent) else { return nil }
        save()
        if moveOriginal {
            try? FileManager.default.trashItem(at: src, resultingItemURL: nil)
        }
        return created
    }

    private func addTree(_ src: URL, parent: String?) -> StashItem? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { return nil }
        let name = uniqueSiblingName(src.lastPathComponent, parent: parent, excluding: nil)

        if isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: src.path) {
            let folder = StashItem(id: UUID().uuidString, name: name, size: 0, date: Date(),
                                   originalPath: src.path, isFolder: true, parentID: parent)
            put(folder)
            let kids = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil, options: [])) ?? []
            for k in kids where k.lastPathComponent != ".DS_Store" { _ = addTree(k, parent: folder.id) }
            return folder
        }

        let id = UUID().uuidString
        let dir = root.appendingPathComponent(id, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(name)
            try fm.copyItem(at: src, to: dest)
            let item = StashItem(id: id, name: name, size: totalSize(dest), date: Date(),
                                 originalPath: src.path, isFolder: false, parentID: parent)
            put(item)
            return item
        } catch {
            try? fm.removeItem(at: dir)
            return nil
        }
    }

    func remove(_ item: StashItem) {
        removeMany([item])
    }

    /// Removes items (folders take everything inside them) and writes the index once.
    func removeMany(_ list: [StashItem]) {
        if list.isEmpty { return }
        let fm = FileManager.default
        var gone = Set<String>()
        for item in list {
            gone.insert(item.id)
            for d in descendants(of: item.id) { gone.insert(d.id) }
        }
        for id in gone {
            try? fm.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
        }
        items.removeAll { gone.contains($0.id) }
        save()
    }

    // MARK: Folders and hierarchy

    /// New items go to the front, so `items` stays newest-first (menus and quick search rely on that).
    private func put(_ item: StashItem) { items.insert(item, at: 0) }

    func item(_ id: String) -> StashItem? { items.first { $0.id == id } }

    func children(of parent: String?) -> [StashItem] { items.filter { $0.parentID == parent } }

    func descendants(of id: String) -> [StashItem] {
        var out: [StashItem] = []
        var queue = [id]
        while let next = queue.popLast() {
            for c in children(of: next) { out.append(c); if c.isFolder { queue.append(c.id) } }
        }
        return out
    }

    /// The chain of folders from the top down to `id` (inclusive). Empty for the top level.
    func chain(to id: String?) -> [StashItem] {
        var out: [StashItem] = []
        var cur = id
        var guardCount = 0
        while let c = cur, let it = item(c), guardCount < 200 {
            out.insert(it, at: 0)
            cur = it.parentID
            guardCount += 1
        }
        return out
    }

    func isDescendant(_ id: String, of ancestor: String) -> Bool {
        return chain(to: id).contains { $0.id == ancestor }
    }

    /// Folders show the total of what is inside them.
    func displaySize(_ item: StashItem) -> Int64 {
        if !item.isFolder { return item.size }
        return descendants(of: item.id).filter { !$0.isFolder }.reduce(0) { $0 + $1.size }
    }

    static func cleanName(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "." || t == ".." || t.contains("/") { return nil }
        return t
    }

    /// `name`, or "name 2", "name 3"... when a sibling already uses it.
    func uniqueSiblingName(_ name: String, parent: String?, excluding: String?) -> String {
        let taken = Set(children(of: parent).filter { $0.id != excluding }.map { $0.name.lowercased() })
        if !taken.contains(name.lowercased()) { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let cand = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(cand.lowercased()) { return cand }
            n += 1
        }
    }

    @discardableResult
    func createFolder(named name: String, in parent: String?) throws -> StashItem {
        guard let clean = Stash.cleanName(name) else { throw StashError.invalidName }
        if let p = parent, item(p)?.isFolder != true { throw StashError.notFound }
        let folder = StashItem(id: UUID().uuidString,
                               name: uniqueSiblingName(clean, parent: parent, excluding: nil),
                               size: 0, date: Date(), originalPath: "", isFolder: true, parentID: parent)
        put(folder)
        save()
        return folder
    }

    func rename(id: String, to newName: String) throws {
        guard let i = items.firstIndex(where: { $0.id == id }) else { throw StashError.notFound }
        guard let clean = Stash.cleanName(newName) else { throw StashError.invalidName }
        let old = items[i]
        if clean == old.name { return }
        if items.contains(where: { $0.parentID == old.parentID && $0.id != id
                                   && $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            throw StashError.nameTaken(clean)
        }
        if !old.isFolder { try renameStored(old, to: clean) }
        items[i].name = clean
        save()
    }

    private func renameStored(_ item: StashItem, to newName: String) throws {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(item.id, isDirectory: true)
        let suffix = item.isPrivate ? Stash.sealedSuffix : ""
        let from = dir.appendingPathComponent(item.name + suffix)
        let to = dir.appendingPathComponent(newName + suffix)
        guard fm.fileExists(atPath: from.path) else { throw StashCryptoError.missingFile(item.name) }
        if from.path.lowercased() == to.path.lowercased() {
            // Case-only change: go through a temporary name so a case-insensitive disk accepts it.
            let tmp = dir.appendingPathComponent(UUID().uuidString)
            try fm.moveItem(at: from, to: tmp)
            try fm.moveItem(at: tmp, to: to)
        } else {
            try fm.moveItem(at: from, to: to)
        }
    }

    /// Moves items into a folder (nil = top level). Returns how many actually moved.
    @discardableResult
    func move(ids: [String], to parent: String?) throws -> Int {
        if let p = parent, item(p)?.isFolder != true { throw StashError.notFound }
        var moved = 0
        defer { if moved > 0 { save() } }
        for id in ids {
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            if items[i].parentID == parent { continue }
            if let p = parent, p == id || isDescendant(p, of: id) {
                throw StashError.cannotMoveIntoSelf(items[i].name)
            }
            let unique = uniqueSiblingName(items[i].name, parent: parent, excluding: id)
            if unique != items[i].name {
                if !items[i].isFolder { try renameStored(items[i], to: unique) }
                items[i].name = unique
            }
            items[i].parentID = parent
            moved += 1
        }
        return moved
    }

    /// Duplicates items (folders with everything inside) into a folder. Names are made unique.
    @discardableResult
    func copy(ids: [String], to parent: String?) throws -> [StashItem] {
        if let p = parent, item(p)?.isFolder != true { throw StashError.notFound }
        var made: [StashItem] = []
        defer { if !made.isEmpty { save() } }
        for id in ids {
            guard let src = item(id) else { continue }
            if let p = parent, src.isFolder, p == id || isDescendant(p, of: id) {
                throw StashError.cannotMoveIntoSelf(src.name)
            }
            made.append(try copyOne(src, to: parent))
        }
        return made
    }

    private func copyOne(_ src: StashItem, to parent: String?) throws -> StashItem {
        let fm = FileManager.default
        var new = src
        new.id = UUID().uuidString
        new.parentID = parent
        new.name = uniqueSiblingName(src.name, parent: parent, excluding: nil)
        new.date = Date()
        if src.isFolder {
            put(new)
            for c in children(of: src.id) { _ = try copyOne(c, to: new.id) }
            return new
        }
        let suffix = src.isPrivate ? Stash.sealedSuffix : ""
        let from = root.appendingPathComponent(src.id, isDirectory: true).appendingPathComponent(src.name + suffix)
        let dstDir = root.appendingPathComponent(new.id, isDirectory: true)
        guard fm.fileExists(atPath: from.path) else { throw StashCryptoError.missingFile(src.name) }
        do {
            try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
            try fm.copyItem(at: from, to: dstDir.appendingPathComponent(new.name + suffix))
        } catch {
            try? fm.removeItem(at: dstDir)
            throw error
        }
        put(new)
        return new
    }

    /// Writes a real copy of an item (folders recursively, private files decrypted) into `dir`.
    @discardableResult
    func materialize(_ item: StashItem, into dir: URL) throws -> URL {
        let fm = FileManager.default
        let dest = uniqueURL(in: dir, name: item.name)
        if item.isFolder {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for c in children(of: item.id) { try materialize(c, into: dest) }
            return dest
        }
        let stored = url(for: item)
        guard fm.fileExists(atPath: stored.path) else { throw StashCryptoError.missingFile(item.name) }
        if item.isPrivate {
            try StashCrypto.open(fileAt: stored, to: dest)
        } else {
            try fm.copyItem(at: stored, to: dest)
        }
        return dest
    }

    /// Older boxes stored an added folder as one opaque directory. Turn each into a real,
    /// navigable folder by moving its contents out into items. Safe to re-run.
    private func migrateLegacyFolders() {
        let fm = FileManager.default
        var changed = false
        for folder in items where folder.isFolder {
            let dir = root.appendingPathComponent(folder.id, isDirectory: true)
            let real = dir.appendingPathComponent(folder.name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: real.path, isDirectory: &isDir), isDir.boolValue else { continue }
            changed = true
            if NSWorkspace.shared.isFilePackage(atPath: real.path) {
                if let i = items.firstIndex(where: { $0.id == folder.id }) { items[i].isFolder = false }
                continue
            }
            let kids = (try? fm.contentsOfDirectory(at: real, includingPropertiesForKeys: nil, options: [])) ?? []
            var ok = true
            for k in kids where ok { ok = explodeMove(k, parent: folder.id) }
            if ok { try? fm.removeItem(at: dir) }
        }
        if changed { save() }
    }

    private func explodeMove(_ src: URL, parent: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { return true }
        let name = src.lastPathComponent
        if name == ".DS_Store" { try? fm.removeItem(at: src); return true }
        if isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: src.path) {
            let folder = StashItem(id: UUID().uuidString, name: name, size: 0, date: Date(),
                                   originalPath: "", isFolder: true, parentID: parent)
            put(folder)
            let kids = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil, options: [])) ?? []
            for k in kids { if !explodeMove(k, parent: folder.id) { return false } }
            try? fm.removeItem(at: src)
            return true
        }
        let id = UUID().uuidString
        let dir = root.appendingPathComponent(id, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(name)
            try fm.moveItem(at: src, to: dest)
            put(StashItem(id: id, name: name, size: totalSize(dest), date: Date(),
                                   originalPath: "", isFolder: false, parentID: parent))
            return true
        } catch {
            try? fm.removeItem(at: dir)
            return false
        }
    }

    /// Replaces the tags and note of one item.
    func setMetadata(id: String, tags: [String], note: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].tags = tags
        items[i].note = note
        save()
    }

    /// "a, b ,c" -> ["a", "b", "c"]. Splits on commas (also full-width ， and 、), trims,
    /// drops empties and repeats (ignoring case).
    static func parseTags(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，、")
        var seen = Set<String>()
        var out: [String] = []
        for part in text.components(separatedBy: separators) {
            let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if seen.insert(t.lowercased()).inserted { out.append(t) }
        }
        return out
    }

    /// Items stored more than `days` days ago.
    func staleItems(olderThanDays days: Int) -> [StashItem] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return [] }
        return items.filter { !$0.isFolder && $0.date < cutoff }
    }
}

func uniqueURL(in dir: URL, name: String) -> URL {
    var candidate = dir.appendingPathComponent(name)
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var n = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        n += 1
    }
    return candidate
}
