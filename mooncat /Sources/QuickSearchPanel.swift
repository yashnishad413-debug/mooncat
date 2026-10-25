import AppKit

// MARK: - Window

/// Borderless floating panel that can become key (so the search field gets typing)
/// even though MoonCat is an accessory app.
private final class QuickSearchWindow: NSPanel {
    var onCancel: (() -> Void)?
    var onResign: (() -> Void)?
    var onReveal: (() -> Void)?

    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }

    // Cmd+Return reveals in Finder.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (event.keyCode == 36 || event.keyCode == 76) && mods.contains(.command) {
            onReveal?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Result row

private final class QuickSearchCell: NSTableCellView {
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.textColor = .labelColor
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // White text on the selection highlight.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = (backgroundStyle == .emphasized)
            titleLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
            detailLabel.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }
}

// MARK: - Controller

/// Spotlight-style search over the Treasure Box. Opened by the global shortcut.
/// Up/Down choose, Return opens, Cmd+Return reveals in Finder, Esc or a click outside closes.
final class QuickSearchPanelController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static let width: CGFloat = 640
    private static let fieldHeight: CGFloat = 56
    private static let rowHeight: CGFloat = 46
    private static let maxRows = 8
    private static let emptyHeight: CGFloat = 44
    private static let bottomPad: CGFloat = 6
    private static let maxResults = 100

    private let panel: QuickSearchWindow
    private let backdrop = NSVisualEffectView()
    private let glass = NSImageView()
    private let field = NSTextField()
    private let divider = NSBox()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private var results: [StashItem] = []
    private var previousApp: NSRunningApplication?
    private var originX: CGFloat = 0
    private var topY: CGFloat = 0
    private var shownAt = Date.distantPast
    private var isDismissing = false
    private var localMonitor: Any?
    private var globalMonitor: Any?

    var isVisible: Bool { return panel.isVisible }

    override init() {
        panel = QuickSearchWindow(contentRect: NSRect(x: 0, y: 0, width: QuickSearchPanelController.width, height: 120),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered,
                                  defer: false)
        super.init()
        build()
    }

    deinit {
        removeMonitors()
    }

    // MARK: Build

    private func build() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.dismiss(restore: true) }
        panel.onReveal = { [weak self] in self?.revealSelected() }
        panel.onResign = { [weak self] in
            guard let self = self else { return }
            // Ignore the key-window shuffle that happens while the panel is still appearing.
            if Date().timeIntervalSince(self.shownAt) < 0.25 { return }
            self.dismiss(restore: false)
        }

        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 14
        backdrop.layer?.masksToBounds = true
        panel.contentView = backdrop

        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        glass.contentTintColor = .secondaryLabelColor
        glass.imageScaling = .scaleProportionallyUpOrDown
        backdrop.addSubview(glass)

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 22, weight: .light)
        field.placeholderString = "Search the Treasure Box"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        backdrop.addSubview(field)

        divider.boxType = .separator
        backdrop.addSubview(divider)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = QuickSearchPanelController.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        backdrop.addSubview(scroll)

        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .left
        backdrop.addSubview(emptyLabel)
    }

    // MARK: Showing and hiding

    func toggle() {
        if panel.isVisible {
            dismiss(restore: true)
        } else {
            show()
        }
    }

    func show() {
        if panel.isVisible { return }

        // Remember who had the focus so Esc can give it back.
        let front = NSWorkspace.shared.frontmostApplication
        if let f = front, f.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = f
        } else {
            previousApp = nil
        }

        // Centre on the screen the cursor is on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxTotal = QuickSearchPanelController.fieldHeight + 1
            + CGFloat(QuickSearchPanelController.maxRows) * QuickSearchPanelController.rowHeight
            + QuickSearchPanelController.bottomPad
        originX = (vf.midX - QuickSearchPanelController.width / 2).rounded()
        topY = (vf.midY + maxTotal / 2).rounded()

        field.stringValue = ""
        refilter()

        shownAt = Date()
        activateApp()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        installMonitors()
    }

    /// `restore` hands the focus back to the app that was in front before the panel opened.
    /// It is only used for Esc and for the shortcut itself: after opening or revealing an item,
    /// or after a click elsewhere, the app being switched to must keep the focus.
    func dismiss(restore: Bool) {
        guard panel.isVisible, !isDismissing else { return }
        isDismissing = true
        let app = restore ? previousApp : nil
        previousApp = nil
        removeMonitors()
        panel.orderOut(nil)
        isDismissing = false
        if let app = app { reactivate(app) }
    }

    private func installMonitors() {
        removeMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks on MoonCat's own windows (for example the cat).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            if let self = self, event.window !== self.panel {
                self.dismiss(restore: false)
            }
            return event
        }
        // Clicks in other apps. Mouse-down monitoring needs no Accessibility permission.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.dismiss(restore: false)
        }
    }

    private func removeMonitors() {
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
    }

    // MARK: Results

    private func refilter() {
        let q = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var scored: [(rank: Int, index: Int, item: StashItem)] = []
        for (i, item) in Stash.shared.items.enumerated() {
            if let r = item.matchRank(q) {
                scored.append((rank: r, index: i, item: item))
            }
        }
        scored.sort { a, b in
            a.rank != b.rank ? a.rank < b.rank : a.index < b.index
        }
        results = scored.prefix(QuickSearchPanelController.maxResults).map { $0.item }

        table.reloadData()
        layoutPanel()
        if !results.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    /// Sizes the panel to the number of results. The top edge stays put, so the
    /// search field does not jump while you type.
    private func layoutPanel() {
        let w = QuickSearchPanelController.width
        let fieldH = QuickSearchPanelController.fieldHeight
        let rowH = QuickSearchPanelController.rowHeight
        let pad = QuickSearchPanelController.bottomPad
        let rows = min(results.count, QuickSearchPanelController.maxRows)
        let listArea: CGFloat = results.isEmpty ? QuickSearchPanelController.emptyHeight : CGFloat(rows) * rowH + pad
        let total = fieldH + 1 + listArea

        panel.setFrame(NSRect(x: originX, y: topY - total, width: w, height: total), display: false)

        glass.frame = NSRect(x: 18, y: total - fieldH + 16, width: 24, height: 24)
        field.frame = NSRect(x: 52, y: total - fieldH + 12, width: w - 52 - 18, height: 32)
        divider.frame = NSRect(x: 0, y: total - fieldH - 1, width: w, height: 1)

        if results.isEmpty {
            scroll.isHidden = true
            emptyLabel.isHidden = false
            emptyLabel.stringValue = Stash.shared.items.isEmpty
                ? "The Treasure Box is empty. Drop a file on the cat to fill it."
                : "No matches."
            emptyLabel.frame = NSRect(x: 18, y: (QuickSearchPanelController.emptyHeight - 18) / 2, width: w - 36, height: 18)
        } else {
            emptyLabel.isHidden = true
            scroll.isHidden = false
            scroll.frame = NSRect(x: 0, y: pad, width: w, height: CGFloat(rows) * rowH)
            table.sizeLastColumnToFit()
        }
    }

    private func selectedItem() -> StashItem? {
        let r = table.selectedRow
        guard r >= 0 && r < results.count else { return nil }
        return results[r]
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let current = table.selectedRow < 0 ? 0 : table.selectedRow
        let next = min(max(current + delta, 0), results.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: Actions

    private func openSelected() {
        guard let item = selectedItem() else {
            NSSound.beep()
            return
        }
        dismiss(restore: false)
        if let url = try? Stash.shared.openableURL(for: item) {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep()
        }
    }

    private func revealSelected() {
        guard let item = selectedItem() else {
            NSSound.beep()
            return
        }
        let url = Stash.shared.url(for: item)
        dismiss(restore: false)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSSound.beep()
        }
    }

    @objc private func rowClicked() {
        let r = table.clickedRow
        guard r >= 0 && r < results.count else { return }
        table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        if NSEvent.modifierFlags.contains(.command) {
            revealSelected()
        } else {
            openSelected()
        }
    }

    // MARK: Search field

    func controlTextDidChange(_ obj: Notification) {
        refilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if NSEvent.modifierFlags.contains(.command) {
                revealSelected()
            } else {
                openSelected()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(restore: true)
            return true
        default:
            return false
        }
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        return results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < results.count else { return nil }
        let item = results[row]
        let ident = NSUserInterfaceItemIdentifier("QuickSearchCell")
        let cell: QuickSearchCell
        if let reused = tableView.makeView(withIdentifier: ident, owner: self) as? QuickSearchCell {
            cell = reused
        } else {
            cell = QuickSearchCell(frame: NSRect(x: 0, y: 0, width: QuickSearchPanelController.width,
                                                 height: QuickSearchPanelController.rowHeight))
            cell.identifier = ident
        }
        cell.iconView.image = Stash.shared.icon(for: item)
        cell.titleLabel.stringValue = (item.isFolder ? "📁 " : "") + (item.isPrivate ? "🔒 " : "") + item.name
        cell.detailLabel.stringValue = detailText(for: item)
        return cell
    }

    /// Second line of a result: tags and the first line of the note, or size and date.
    private func detailText(for item: StashItem) -> String {
        var parts: [String] = []
        if !item.tags.isEmpty {
            parts.append(item.tags.map { "#" + $0 }.joined(separator: " "))
        }
        let firstLine = item.note
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !firstLine.isEmpty { parts.append(firstLine) }
        if parts.isEmpty {
            let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
            let date = DateFormatter.localizedString(from: item.date, dateStyle: .medium, timeStyle: .none)
            return "\(size) · stored \(date)"
        }
        return parts.joined(separator: " — ")
    }
}
