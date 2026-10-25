import AppKit

struct Reminder: Codable {
    var id: String
    var title: String
    var fireDate: Date

    /// What to show when the title is empty ("5m" with no text).
    var displayTitle: String { return title.isEmpty ? "Reminder" : title }
}

/// Quick reminders ("20m stretch", "3pm call mom"). Saved as JSON, so they survive a relaunch.
/// A system banner is scheduled for each one (it also shows if MoonCat is not running),
/// and an in-app timer makes the cat react at the same moment.
final class ReminderStore: NSObject {
    static let shared = ReminderStore()
    static let didChange = Notification.Name("MoonCatRemindersDidChange")

    private let fileURL: URL
    private var reminders: [Reminder] = []
    private var timer: Timer?

    /// Called on the main thread when a reminder falls due.
    var onFire: ((Reminder) -> Void)?

    var all: [Reminder] { return reminders.sorted { $0.fireDate < $1.fireDate } }

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("MoonCat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("reminders.json")
        super.init()
        load()
    }

    /// Call once at launch: fires anything that came due while MoonCat was closed, re-arms the
    /// banners for the rest, and starts the timer.
    func start() {
        let now = Date()
        let late = reminders.filter { $0.fireDate <= now }
        if !late.isEmpty {
            reminders.removeAll { $0.fireDate <= now }
            save()
            for r in late {
                // Same id replaces a banner that may already have been delivered, so no duplicates.
                Notifier.shared.schedule(id: r.id, title: "Moon Cat reminder", body: r.displayTitle, at: now)
                onFire?(r)
            }
        }
        for r in reminders {
            Notifier.shared.schedule(id: r.id, title: "Moon Cat reminder", body: r.displayTitle, at: r.fireDate)
        }
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(timerTick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func add(_ reminder: Reminder) {
        reminders.append(reminder)
        save()
        Notifier.shared.ensureAuthorized { [weak self] _ in
            self?.armBanner(reminder)
        }
    }

    func remove(id: String) {
        reminders.removeAll { $0.id == id }
        save()
        Notifier.shared.cancel(id: id)
    }

    private func armBanner(_ r: Reminder) {
        // Skip if it was removed while the permission dialog was open.
        guard reminders.contains(where: { $0.id == r.id }) else { return }
        Notifier.shared.schedule(id: r.id, title: "Moon Cat reminder", body: r.displayTitle, at: r.fireDate)
    }

    @objc private func timerTick() {
        let now = Date()
        let due = reminders.filter { $0.fireDate <= now }
        if due.isEmpty { return }
        reminders.removeAll { $0.fireDate <= now }
        save()
        // The scheduled banner delivers itself at this moment; we only react.
        for r in due { onFire?(r) }
    }

    // MARK: Persistence

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(reminders) {
            try? data.write(to: fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: ReminderStore.didChange, object: self)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        reminders = (try? dec.decode([Reminder].self, from: data)) ?? []
    }

    // MARK: UI

    private static var listController: ReminderListController?

    /// Small dialog: type "20m stretch", press Add.
    static func promptAndAdd() {
        let alert = NSAlert()
        alert.messageText = "Remind me…"
        alert.informativeText = "Try: 20m stretch · 1h30m tea · 3pm call mom · tomorrow 9am meeting"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "time and what, e.g. 20m stretch"
        alert.accessoryView = input
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input

        activateApp()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let parsed = ReminderParser.parse(text) {
            shared.add(Reminder(id: UUID().uuidString, title: parsed.title, fireDate: parsed.fireDate))
        } else {
            let err = NSAlert()
            err.messageText = "I couldn't find a time in “\(text)”."
            err.informativeText = "Start with a time: 20m stretch, 1h30m tea, in 2 hours laundry, 3pm call mom, 15:30 standup, tomorrow 9am dentist."
            err.addButton(withTitle: "OK")
            err.runModal()
        }
    }

    static func showList() {
        if listController == nil { listController = ReminderListController() }
        listController?.show()
    }
}

// MARK: - List window

private final class ReminderListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    let table = NSTableView()
    private var items: [Reminder] = []

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered,
                          defer: false)
        super.init()
        window.title = "Moon Cat Reminders"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 220)
        window.center()
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(changed),
                                               name: ReminderStore.didChange, object: nil)
    }

    private func build() {
        guard let content = window.contentView else { return }
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 52, width: 436, height: 256))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]

        for (ident, title, width) in [("title", "Reminder", 250.0), ("when", "When", 170.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ident))
            col.title = title
            col.width = CGFloat(width)
            col.minWidth = 80
            col.isEditable = false
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        scroll.documentView = table
        content.addSubview(scroll)

        let add = NSButton(title: "Add…", target: self, action: #selector(addTapped))
        add.bezelStyle = .rounded
        add.frame = NSRect(x: 12, y: 14, width: 80, height: 28)
        add.autoresizingMask = [.maxXMargin, .maxYMargin]
        content.addSubview(add)

        let del = NSButton(title: "Delete", target: self, action: #selector(deleteTapped))
        del.bezelStyle = .rounded
        del.frame = NSRect(x: 460 - 12 - 80, y: 14, width: 80, height: 28)
        del.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(del)
    }

    func show() {
        reload()
        activateApp()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func changed() { reload() }

    private func reload() {
        items = ReminderStore.shared.all
        table.reloadData()
        window.title = items.isEmpty ? "Moon Cat Reminders" : "Moon Cat Reminders — \(items.count)"
    }

    @objc private func addTapped() {
        ReminderStore.promptAndAdd()
        reload()
    }

    @objc private func deleteTapped() {
        let rows = table.selectedRowIndexes
        for r in rows where r < items.count { ReminderStore.shared.remove(id: items[r].id) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { return items.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < items.count, let ident = tableColumn?.identifier.rawValue else { return nil }
        let r = items[row]
        if ident == "title" { return r.displayTitle }
        return DateFormatter.localizedString(from: r.fireDate, dateStyle: .medium, timeStyle: .short)
    }
}
