import AppKit
import QuickLookUI
import QuickLookThumbnailing

// MARK: - Helpers

/// Pasteboard type that carries Treasure Box item ids (drag to move, copy/cut/paste).
let stashMoveType = NSPasteboard.PasteboardType("com.mooncat.stash.items")

/// What the window is showing: a folder (nil = top level), or one of the flat smart views.
enum StashLocation: Equatable {
    case folder(String?)
    case recents
    case locked
}

final class SidebarNode: NSObject {
    let title: String
    let symbol: String
    let location: StashLocation
    var children: [SidebarNode] = []
    init(title: String, symbol: String, location: StashLocation) {
        self.title = title
        self.symbol = symbol
        self.location = location
    }
    var key: String {
        if case .folder(let id) = location { return id ?? "" }
        return title
    }
}

/// Hands the real file URL to a drop target only when it asks, so plain moves inside the box
/// never decrypt or copy anything.
final class StashDragProvider: NSObject, NSPasteboardItemDataProvider {
    let item: StashItem
    init(_ item: StashItem) { self.item = item }
    func pasteboard(_ pasteboard: NSPasteboard?, item pbItem: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        if type == .fileURL, let url = try? Stash.shared.openableURL(for: item, keepFor: 600) {
            pbItem.setString(url.absoluteString, forType: .fileURL)
        }
    }
}

// MARK: - Table that can drive the Quick Look panel

/// Space toggles the preview. The table is the responder Quick Look talks to,
/// so it hands the panel over to the Treasure Box window controller.
final class StashTableView: NSTableView {
    weak var previewOwner: StashWindowController?
    var onSpace: (() -> Void)?
    /// Finder-style shortcuts (Return renames, ⌘C/X/V, ⌘↑/↓ ...). Returns true when handled.
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 49 && mods.isEmpty {
            onSpace?()
            return
        }
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only while the list itself has focus, so ⌘C in the search field still copies text.
        if window?.firstResponder === self, onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = previewOwner
        panel.delegate = previewOwner
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

// MARK: - View mode and sort

enum StashViewMode: Int { case list, icon, column }

enum StashSortKey: Int, CaseIterable {
    case name, date, size, kind
    var title: String { return ["Name", "Date", "Size", "Kind"][rawValue] }
}

// MARK: - Treasure Box window

final class StashWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                                   NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation,
                                   NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate,
                                   QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let window: NSWindow
    let table = StashTableView()
    let outline = NSOutlineView()
    let search = NSSearchField()
    let tagsField = NSTextField()
    let noteView = NSTextView()
    var shown: [StashItem] = []
    private let emptyArt = ArtEmptyView()
    var onAdd: (([URL]) -> Void)?

    private(set) var location: StashLocation = .folder(nil)
    private var backStack: [StashLocation] = []
    private var forwardStack: [StashLocation] = []
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let pathBar = NSStackView()
    private var pathTargets: [StashLocation] = []
    private var roots: [SidebarNode] = []
    private var expandedIDs: Set<String> = [""]
    private var restoringExpansion = false
    private var syncingSidebar = false
    private var dragProviders: [String: StashDragProvider] = [:]

    private let thumbCache = NSCache<NSString, NSImage>()
    private let iconCache = NSCache<NSString, NSImage>()
    private var thumbPending = Set<String>()
    private var editingID: String?          // the item whose tags and note are in the editor
    private var isCommitting = false
    private var privateButton: NSButton?
    private let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sortDirButton = NSButton()
    private let viewSwitch = NSSegmentedControl()
    private var listScroll: NSScrollView?
    private let iconScroll = NSScrollView()
    private let collection = NSCollectionView()
    private let browser = NSBrowser()
    private var colNodes: [String: ColumnNode] = [:]

    var sortKey: StashSortKey {
        get { return StashSortKey(rawValue: UserDefaults.standard.integer(forKey: "stashSortKey")) ?? .name }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "stashSortKey") }
    }
    var sortAscending: Bool {
        get { return UserDefaults.standard.object(forKey: "stashSortAsc") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "stashSortAsc") }
    }
    var viewMode: StashViewMode {
        get { return StashViewMode(rawValue: UserDefaults.standard.integer(forKey: "stashViewMode")) ?? .list }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "stashViewMode") }
    }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        super.init()
        Theme.style(window)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 420)
        window.delegate = self
        window.center()
        thumbCache.countLimit = 600
        iconCache.countLimit = 600
        build()
        reload()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(stashChanged), name: Stash.didChange, object: nil)
        nc.addObserver(self, selector: #selector(appWillTerminate),
                       name: NSApplication.willTerminateNotification, object: nil)
    }

    func build() {
        guard let content = window.contentView else { return }
        let sidebarW: CGFloat = 170
        let W: CGFloat = 860 - sidebarW - 1
        let H: CGFloat = 560
        let editorH: CGFloat = 108

        // Finder-style layout: a folder sidebar on the left, the listing on the right.
        let split = NSSplitView(frame: content.bounds)
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]

        let sideScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: sidebarW, height: H))
        sideScroll.hasVerticalScroller = true
        sideScroll.drawsBackground = false
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("side"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([stashMoveType, .fileURL])
        sideScroll.documentView = outline

        let right = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        right.autoresizingMask = [.width, .height]
        split.addSubview(sideScroll)
        split.addSubview(right)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        content.addSubview(split)
        split.setPosition(sidebarW, ofDividerAt: 0)

        // Top row: back, forward, path, search.
        for (b, symbol, sel, tip) in [(backButton, "chevron.left", #selector(goBack), "Back"),
                                      (forwardButton, "chevron.right", #selector(goForward), "Forward")] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            b.target = self
            b.action = sel
            b.autoresizingMask = [.maxXMargin, .minYMargin]
            right.addSubview(b)
        }
        backButton.frame = NSRect(x: 12, y: H - 40, width: 30, height: 24)
        forwardButton.frame = NSRect(x: 44, y: H - 40, width: 30, height: 24)

        search.frame = NSRect(x: W - 12 - 190, y: H - 40, width: 190, height: 24)
        search.placeholderString = "Search names, tags and notes"
        search.autoresizingMask = [.minXMargin, .minYMargin]
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        right.addSubview(search)

        pathBar.orientation = .horizontal
        pathBar.spacing = 2
        pathBar.alignment = .centerY
        pathBar.distribution = .gravityAreas
        pathBar.frame = NSRect(x: 84, y: H - 40, width: W - 84 - 12 - 190 - 8, height: 24)
        pathBar.autoresizingMask = [.width, .minYMargin]
        right.addSubview(pathBar)

        // Second row: sort menu, direction, and the List / Icon / Column switcher.
        sortPopup.addItems(withTitles: StashSortKey.allCases.map { $0.title })
        sortPopup.selectItem(at: sortKey.rawValue)
        sortPopup.target = self
        sortPopup.action = #selector(sortKeyChanged)
        sortPopup.toolTip = "Sort by"
        sortPopup.frame = NSRect(x: 12, y: H - 70, width: 90, height: 24)
        sortPopup.autoresizingMask = [.maxXMargin, .minYMargin]
        right.addSubview(sortPopup)

        sortDirButton.bezelStyle = .texturedRounded
        sortDirButton.target = self
        sortDirButton.action = #selector(sortDirChanged)
        sortDirButton.frame = NSRect(x: 106, y: H - 70, width: 30, height: 24)
        sortDirButton.autoresizingMask = [.maxXMargin, .minYMargin]
        right.addSubview(sortDirButton)
        updateSortDirButton()

        let cleanButton = NSButton(title: "Clean Up…", target: self, action: #selector(cleanUp))
        cleanButton.bezelStyle = .texturedRounded
        cleanButton.toolTip = "Find identical copies and old files"
        cleanButton.frame = NSRect(x: 146, y: H - 70, width: 86, height: 24)
        cleanButton.autoresizingMask = [.maxXMargin, .minYMargin]
        right.addSubview(cleanButton)

        viewSwitch.segmentCount = 3
        for (i, (symbol, tip)) in [("list.bullet", "List"), ("square.grid.2x2", "Icons"),
                                   ("rectangle.split.3x1", "Columns")].enumerated() {
            viewSwitch.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: tip), forSegment: i)
            viewSwitch.setWidth(34, forSegment: i)
        }
        viewSwitch.selectedSegment = viewMode.rawValue
        viewSwitch.trackingMode = .selectOne
        viewSwitch.target = self
        viewSwitch.action = #selector(viewModeChanged)
        viewSwitch.frame = NSRect(x: W - 12 - 102, y: H - 70, width: 102, height: 24)
        viewSwitch.autoresizingMask = [.minXMargin, .minYMargin]
        right.addSubview(viewSwitch)

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 52 + editorH + 8, width: W - 24, height: H - 78 - (52 + editorH + 8)))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.borderType = .bezelBorder

        let cols: [(String, String, CGFloat)] = [("thumb", "", 44), ("name", "Name", 250), ("tags", "Tags", 140),
                                                 ("size", "Size", 80), ("date", "Stored", 140)]
        for (ident, title, width) in cols {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ident))
            col.title = title
            col.width = width
            col.minWidth = 60
            col.isEditable = (ident == "name")
            if ident == "thumb" {
                col.minWidth = 44
                col.maxWidth = 44
                col.resizingMask = []
                let imageCell = NSImageCell()
                imageCell.imageScaling = .scaleProportionallyUpOrDown
                imageCell.imageAlignment = .alignCenter
                col.dataCell = imageCell
            }
            table.addTableColumn(col)
        }
        table.rowHeight = 40
        table.dataSource = self
        table.delegate = self
        table.previewOwner = self
        table.onSpace = { [weak self] in self?.togglePreview() }
        table.onKey = { [weak self] in self?.handleKey($0) ?? false }
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(openSelected)
        // Dragging out of the window copies; dragging onto a folder inside the box moves.
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.registerForDraggedTypes([stashMoveType, .fileURL])
        table.menu = buildContextMenu()
        scroll.documentView = table
        right.addSubview(scroll)
        listScroll = scroll

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 100, height: 100)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        collection.collectionViewLayout = layout
        collection.autoresizingMask = [.width]
        collection.register(StashIconItem.self, forItemWithIdentifier: StashIconItem.id)
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.menu = buildContextMenu()
        let dbl = NSClickGestureRecognizer(target: self, action: #selector(iconDoubleClicked))
        dbl.numberOfClicksRequired = 2
        dbl.delaysPrimaryMouseButtonEvents = false
        collection.addGestureRecognizer(dbl)
        iconScroll.frame = scroll.frame
        iconScroll.autoresizingMask = [.width, .height]
        iconScroll.hasVerticalScroller = true
        iconScroll.borderType = .bezelBorder
        iconScroll.documentView = collection
        right.addSubview(iconScroll)

        browser.frame = scroll.frame
        browser.autoresizingMask = [.width, .height]
        browser.delegate = self
        browser.allowsMultipleSelection = true
        browser.hasHorizontalScroller = true
        browser.target = self
        browser.doubleAction = #selector(browserDoubleClicked)
        browser.menu = buildContextMenu()
        right.addSubview(browser)
        emptyArt.frame = scroll.frame
        emptyArt.autoresizingMask = [.width, .height]
        right.addSubview(emptyArt)
        applyViewMode()

        buildEditor(in: right, width: W, height: editorH)

        @discardableResult
        func button(_ title: String, _ action: Selector, x: CGFloat, width: CGFloat, right isRight: Bool = false) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.frame = NSRect(x: x, y: 14, width: width, height: 28)
            b.autoresizingMask = isRight ? [.minXMargin, .maxYMargin] : [.maxXMargin, .maxYMargin]
            right.addSubview(b)
            return b
        }
        button("Add Files…", #selector(addFiles), x: 12, width: 98)
        button("New Folder", #selector(newFolder), x: 114, width: 92)
        button("Open", #selector(openSelected), x: 210, width: 58)
        button("Show in Finder", #selector(revealSelected), x: 272, width: 116)
        button("Save a Copy…", #selector(saveCopy), x: 392, width: 104)
        privateButton = button("Lock", #selector(togglePrivate), x: 500, width: 70)
        updatePrivateButton()
        button("Delete", #selector(deleteSelected), x: W - 12 - 80, width: 80, right: true)
    }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func searchChanged() { reload() }

    // MARK: Navigation

    /// Id of the folder being viewed, or nil at the top level and in the flat views.
    var currentFolderID: String? {
        if case .folder(let id) = location { return id }
        return nil
    }

    private var isSearching: Bool {
        return !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when new items can be put straight into what is on screen.
    private var inFolderView: Bool {
        if case .folder = location, !isSearching { return true }
        return false
    }

    func navigate(to loc: StashLocation) {
        if loc == location && !isSearching { return }
        commitEdits()
        if loc != location {
            backStack.append(location)
            forwardStack.removeAll()
        }
        location = loc
        search.stringValue = ""
        reload()
    }

    @objc func goBack() {
        guard let prev = backStack.popLast() else { return }
        commitEdits()
        forwardStack.append(location)
        location = prev
        search.stringValue = ""
        reload()
    }

    @objc func goForward() {
        guard let next = forwardStack.popLast() else { return }
        commitEdits()
        backStack.append(location)
        location = next
        search.stringValue = ""
        reload()
    }

    @objc func goUp() {
        if case .folder(let id?) = location {
            navigate(to: .folder(Stash.shared.item(id)?.parentID))
        }
    }

    // MARK: Listing

    /// Folders first, then by the chosen key and direction; ties fall back to name.
    func sortedItems(_ list: [StashItem]) -> [StashItem] {
        let key = sortKey, asc = sortAscending
        let st = Stash.shared
        var sizes: [String: Int64] = [:]
        if key == .size { for it in list { sizes[it.id] = st.displaySize(it) } }
        func kind(_ i: StashItem) -> String {
            return i.isFolder ? "" : (i.name as NSString).pathExtension.lowercased()
        }
        func cmp<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult {
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        }
        return list.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let r: ComparisonResult
            switch key {
            case .name: r = a.name.localizedStandardCompare(b.name)
            case .date: r = cmp(a.date, b.date)
            case .size: r = cmp(sizes[a.id] ?? 0, sizes[b.id] ?? 0)
            case .kind: r = kind(a).compare(kind(b))
            }
            if r == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
    }

    @objc private func sortKeyChanged() {
        sortKey = StashSortKey(rawValue: sortPopup.indexOfSelectedItem) ?? .name
        reload()
    }

    @objc private func sortDirChanged() {
        sortAscending.toggle()
        updateSortDirButton()
        reload()
    }

    private func updateSortDirButton() {
        let name = sortAscending ? "arrow.up" : "arrow.down"
        sortDirButton.image = NSImage(systemSymbolName: name, accessibilityDescription: "Sort direction")
        sortDirButton.toolTip = sortAscending ? "Ascending" : "Descending"
    }

    @objc private func cleanUp() { StashCleanupUI.present(on: window) }

    @objc private func viewModeChanged() {
        viewMode = StashViewMode(rawValue: viewSwitch.selectedSegment) ?? .list
        reload()
    }

    func reload() {
        commitEdits()
        let st = Stash.shared
        // A folder that no longer exists (deleted elsewhere) sends the window back to the top.
        if case .folder(let id?) = location, st.item(id)?.isFolder != true {
            location = .folder(nil)
            backStack.removeAll { $0 == .folder(id) }
            forwardStack.removeAll { $0 == .folder(id) }
        }
        let keep = Set(selected().map { $0.id })
        let q = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let ranked = st.items.compactMap { it in it.matchRank(q).map { (it, $0) } }
            shown = ranked.sorted { a, b in
                a.1 != b.1 ? a.1 < b.1 : a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
            }.map { $0.0 }
        } else {
            switch location {
            case .folder(let id):
                shown = sortedItems(st.children(of: id))
            case .recents:
                shown = Array(st.items.filter { !$0.isFolder }.sorted { $0.date > $1.date }.prefix(100))
            case .locked:
                shown = sortedItems(st.items.filter { $0.isPrivate })
            }
        }
        table.reloadData()
        if isSearching {
            emptyArt.update(art: "stash_search_empty", text: "Nothing matches that search.", visible: shown.isEmpty)
        } else {
            emptyArt.update(art: "stash_empty", text: "Nothing here yet. Drop something on Moon, or press Add Files.", visible: shown.isEmpty)
        }
        let rows = IndexSet(shown.enumerated().filter { keep.contains($0.element.id) }.map { $0.offset })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        refreshViews(selecting: rows)
        loadEditor()
        rebuildSidebar()
        rebuildPathBar()
        backButton.isEnabled = !backStack.isEmpty
        forwardButton.isEnabled = !forwardStack.isEmpty
        window.title = "Moon Cat's Treasure Box - \(locationTitle) (\(shown.count))"
    }

    private var locationTitle: String {
        if isSearching { return "Search" }
        switch location {
        case .folder(let id): return id.flatMap { Stash.shared.item($0)?.name } ?? "Treasure Box"
        case .recents: return "Recents"
        case .locked: return "Locked"
        }
    }

    func selected() -> [StashItem] {
        if viewMode == .column { return columnSelection }
        return table.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0] : nil }
    }

    // MARK: Path bar

    private func rebuildPathBar() {
        for v in pathBar.arrangedSubviews { pathBar.removeArrangedSubview(v); v.removeFromSuperview() }
        var comps: [(String, StashLocation)] = []
        switch location {
        case .folder(let id):
            comps = [("Treasure Box", .folder(nil))] + Stash.shared.chain(to: id).map { ($0.name, StashLocation.folder($0.id)) }
        case .recents: comps = [("Recents", .recents)]
        case .locked: comps = [("Locked", .locked)]
        }
        if isSearching { comps.append(("Search results", location)) }
        pathTargets = comps.map { $0.1 }
        for (i, c) in comps.enumerated() {
            if i > 0 {
                let sep = NSTextField(labelWithString: "›")
                sep.textColor = .tertiaryLabelColor
                pathBar.addArrangedSubview(sep)
            }
            let b = NSButton(title: c.0, target: self, action: #selector(pathClicked(_:)))
            b.isBordered = false
            b.tag = i
            let last = (i == comps.count - 1)
            b.font = last ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 12)
            b.lineBreakMode = .byTruncatingTail
            pathBar.addArrangedSubview(b)
        }
    }

    @objc private func pathClicked(_ sender: NSButton) {
        guard sender.tag >= 0 && sender.tag < pathTargets.count else { return }
        navigate(to: pathTargets[sender.tag])
    }

    // MARK: Sidebar

    private func rebuildSidebar() {
        func folderNodes(_ parent: String?) -> [SidebarNode] {
            return Stash.shared.children(of: parent).filter { $0.isFolder }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { f in
                    let n = SidebarNode(title: f.name, symbol: "folder", location: .folder(f.id))
                    n.children = folderNodes(f.id)
                    return n
                }
        }
        let box = SidebarNode(title: "Treasure Box", symbol: "archivebox", location: .folder(nil))
        box.children = folderNodes(nil)
        roots = [SidebarNode(title: "Recents", symbol: "clock", location: .recents),
                 SidebarNode(title: "Locked", symbol: "lock", location: .locked),
                 box]
        restoringExpansion = true
        outline.reloadData()
        func restore(_ n: SidebarNode) {
            if !n.children.isEmpty && expandedIDs.contains(n.key) { outline.expandItem(n) }
            n.children.forEach(restore)
        }
        roots.forEach(restore)
        restoringExpansion = false
        syncSidebarSelection()
    }

    private func node(for loc: StashLocation, in list: [SidebarNode]) -> SidebarNode? {
        for n in list {
            if n.location == loc { return n }
            if let hit = node(for: loc, in: n.children) { return hit }
        }
        return nil
    }

    private func syncSidebarSelection() {
        syncingSidebar = true
        defer { syncingSidebar = false }
        if case .folder(let id) = location {
            // Open the folders leading to the current one so it is visible in the tree.
            if id != nil, let top = roots.last { outline.expandItem(top) }
            for f in Stash.shared.chain(to: id).dropLast() {
                if let n = node(for: .folder(f.id), in: roots) { outline.expandItem(n) }
            }
        }
        if let n = node(for: location, in: roots) {
            let row = outline.row(forItem: n)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        } else {
            outline.deselectAll(nil)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        return (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let n = item as? SidebarNode { return n.children[index] }
        return roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return !((item as? SidebarNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("sidebarCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeSidebarCell(id)
        cell.textField?.stringValue = node.title
        cell.imageView?.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: node.title)
        return cell
    }

    private func makeSidebarCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        cell.addSubview(iv)
        cell.addSubview(tf)
        cell.imageView = iv
        cell.textField = tf
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16),
            iv.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if syncingSidebar { return }
        let row = outline.selectedRow
        guard row >= 0, let n = outline.item(atRow: row) as? SidebarNode else { return }
        navigate(to: n.location)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? SidebarNode { expandedIDs.insert(n.key) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if restoringExpansion { return }
        if let n = notification.userInfo?["NSObject"] as? SidebarNode { expandedIDs.remove(n.key) }
    }

    // Dropping on a sidebar folder moves (or copies in) there.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let n = item as? SidebarNode, case .folder(let target) = n.location else { return [] }
        if index != NSOutlineViewDropOnItemIndex { outlineView.setDropItem(n, dropChildIndex: NSOutlineViewDropOnItemIndex) }
        return dropOperation(info, target: target)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let n = item as? SidebarNode, case .folder(let target) = n.location else { return false }
        return performDrop(info, target: target)
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        return shown.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < shown.count, let ident = tableColumn?.identifier.rawValue else { return nil }
        let it = shown[row]
        switch ident {
        case "thumb":
            return thumbnail(for: it)
        case "name":
            return it.name
        case "tags":
            return it.tags.joined(separator: ", ")
        case "size":
            if it.isFolder {
                let n = Stash.shared.children(of: it.id).count
                return n == 1 ? "1 item" : "\(n) items"
            }
            return ByteCountFormatter.string(fromByteCount: it.size, countStyle: .file)
        default:
            return DateFormatter.localizedString(from: it.date, dateStyle: .medium, timeStyle: .short)
        }
    }

    /// Renaming in the list (Return, or click a selected name).
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard tableColumn?.identifier.rawValue == "name", row < shown.count, let text = object as? String else { return }
        do {
            try Stash.shared.rename(id: shown[row].id, to: text)
        } catch {
            showError(error)
        }
        reload()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < shown.count else { return nil }
        let item = shown[row]
        let pb = NSPasteboardItem()
        pb.setString(item.id, forType: stashMoveType)
        // The real file (decrypted for a private item, a temp copy kept for 10 minutes) is made only when a
        // target outside the box asks for it.
        let provider = StashDragProvider(item)
        dragProviders[item.id] = provider
        pb.setDataProvider(provider, forTypes: [.fileURL])
        return pb
    }

    // MARK: Drag and drop

    private func draggedIDs(_ info: NSDraggingInfo) -> [String] {
        return (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: stashMoveType) }
    }

    private func draggedFileURLs(_ info: NSDraggingInfo) -> [URL] {
        let objs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true])
        return (objs as? [URL]) ?? []
    }

    /// .move for items from this box, .copy for files from outside, [] when the drop makes no sense.
    private func dropOperation(_ info: NSDraggingInfo, target: String?) -> NSDragOperation {
        let ids = draggedIDs(info)
        if !ids.isEmpty {
            let st = Stash.shared
            for id in ids {
                if let t = target, t == id || st.isDescendant(t, of: id) { return [] }
            }
            // Nothing to do when everything already sits in the target.
            if ids.allSatisfy({ st.item($0)?.parentID == target }) { return [] }
            return .move
        }
        return draggedFileURLs(info).isEmpty ? [] : .copy
    }

    private func performDrop(_ info: NSDraggingInfo, target: String?) -> Bool {
        let ids = draggedIDs(info)
        if !ids.isEmpty {
            do {
                try Stash.shared.move(ids: ids, to: target)
            } catch {
                showError(error)
            }
            reload()
            return true
        }
        let urls = draggedFileURLs(info)
        if urls.isEmpty { return false }
        for u in urls { Stash.shared.add(u, moveOriginal: false, parent: target) }
        reload()
        return true
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard inFolderView else { return [] }
        let target: String?
        if op == .on, row >= 0, row < shown.count, shown[row].isFolder {
            target = shown[row].id
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
            target = currentFolderID
        }
        return dropOperation(info, target: target)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard inFolderView else { return false }
        let target: String? = (op == .on && row >= 0 && row < shown.count && shown[row].isFolder)
            ? shown[row].id : currentFolderID
        return performDrop(info, target: target)
    }

    // MARK: Tags and note editor

    private func buildEditor(in content: NSView, width W: CGFloat, height editorH: CGFloat) {
        let editor = NSView(frame: NSRect(x: 12, y: 52, width: W - 24, height: editorH))
        editor.autoresizingMask = [.width, .maxYMargin]
        let w = editor.frame.width

        func label(_ text: String, y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 0, y: y, width: 44, height: 17)
            l.alignment = .right
            l.textColor = .secondaryLabelColor
            l.autoresizingMask = [.maxXMargin]
            return l
        }
        editor.addSubview(label("Tags", y: editorH - 22))
        editor.addSubview(label("Note", y: 53))

        tagsField.frame = NSRect(x: 52, y: editorH - 26, width: w - 52, height: 24)
        tagsField.autoresizingMask = [.width]
        tagsField.placeholderString = "comma, separated, tags"
        tagsField.delegate = self
        tagsField.target = self
        tagsField.action = #selector(tagsEntered)
        editor.addSubview(tagsField)

        let noteScroll = NSScrollView(frame: NSRect(x: 52, y: 0, width: w - 52, height: 72))
        noteScroll.hasVerticalScroller = true
        noteScroll.borderType = .bezelBorder
        noteScroll.autoresizingMask = [.width]
        noteView.frame = NSRect(x: 0, y: 0, width: noteScroll.contentSize.width, height: 72)
        noteView.minSize = NSSize(width: 0, height: 72)
        noteView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        noteView.isVerticallyResizable = true
        noteView.isHorizontallyResizable = false
        noteView.autoresizingMask = [.width]
        noteView.textContainer?.widthTracksTextView = true
        noteView.isRichText = false
        noteView.allowsUndo = true
        noteView.font = NSFont.systemFont(ofSize: 13)
        noteView.isAutomaticQuoteSubstitutionEnabled = false
        noteView.isAutomaticDashSubstitutionEnabled = false
        noteView.delegate = self
        noteScroll.documentView = noteView
        editor.addSubview(noteScroll)

        content.addSubview(editor)
    }

    /// Shows the tags and note of the selected item. Editing is only offered for exactly one item.
    private func loadEditor() {
        let sel = selected()
        if sel.count == 1 {
            let it = sel[0]
            editingID = it.id
            tagsField.stringValue = it.tags.joined(separator: ", ")
            tagsField.placeholderString = "comma, separated, tags"
            tagsField.isEnabled = true
            noteView.string = it.note
            noteView.isEditable = true
        } else {
            editingID = nil
            tagsField.stringValue = ""
            tagsField.placeholderString = sel.isEmpty ? "Select an item to add tags" : "Select one item to edit its tags"
            tagsField.isEnabled = false
            noteView.string = ""
            noteView.isEditable = false
        }
    }

    /// Writes the editor back to the item it was loaded from (not necessarily the current selection).
    func commitEdits() {
        guard let id = editingID, !isCommitting,
              let current = Stash.shared.items.first(where: { $0.id == id }) else { return }
        let newTags = Stash.parseTags(tagsField.stringValue)
        let newNote = noteView.string
        if newTags == current.tags && newNote == current.note { return }

        isCommitting = true
        Stash.shared.setMetadata(id: id, tags: newTags, note: newNote)
        isCommitting = false

        // Update the visible copy in place, so an item does not vanish from a filtered list mid-edit.
        if let idx = shown.firstIndex(where: { $0.id == id }) {
            shown[idx].tags = newTags
            shown[idx].note = newNote
            table.reloadData(forRowIndexes: IndexSet(integer: idx),
                             columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
    }

    @objc func tagsEntered() {
        commitEdits()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitEdits()
    }

    func textDidEndEditing(_ notification: Notification) {
        commitEdits()
    }

    @objc func stashChanged() {
        if isCommitting { return }
        reload()
    }

    @objc func appWillTerminate() {
        commitEdits()
    }

    func windowWillClose(_ notification: Notification) {
        commitEdits()
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        commitEdits()
        loadEditor()
        updatePrivateButton()
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    // MARK: Thumbnails

    /// The cached thumbnail, or the file's icon right now while the real thumbnail is generated.
    private func thumbnail(for item: StashItem) -> NSImage {
        let key = item.id as NSString
        // Private items only ever show a lock: their contents are never decrypted for a preview.
        if item.isPrivate { return lockImage }
        if item.isFolder { return Stash.shared.icon(for: item) }
        if let img = thumbCache.object(forKey: key) { return img }
        requestThumbnail(for: item)
        if let icon = iconCache.object(forKey: key) { return icon }
        let icon = Stash.shared.icon(for: item)
        iconCache.setObject(icon, forKey: key)
        return icon
    }

    private var lockImage: NSImage {
        return NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Private")
            ?? NSImage(named: NSImage.lockLockedTemplateName)
            ?? NSImage()
    }

    private func requestThumbnail(for item: StashItem) {
        if thumbPending.contains(item.id) { return }
        thumbPending.insert(item.id)
        let id = item.id
        let url = Stash.shared.url(for: item)
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: 64, height: 64),
                                                   scale: window.backingScaleFactor,
                                                   representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.thumbPending.remove(id)
                // On any failure the file icon becomes the cached image, so we do not ask again.
                let image = rep?.nsImage ?? NSWorkspace.shared.icon(forFile: url.path)
                self.thumbCache.setObject(image, forKey: id as NSString)
                if let row = self.shown.firstIndex(where: { $0.id == id }) {
                    self.table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                    if self.viewMode == .icon { self.collection.reloadItems(at: [IndexPath(item: row, section: 0)]) }
                }
            }
        }
    }

    // MARK: Quick Look

    var previewURLs: [URL] {
        // Private items are skipped: Quick Look would need a decrypted copy on disk.
        return selected()
            .filter { !$0.isPrivate && !$0.isFolder }
            .map { Stash.shared.url(for: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    @objc func togglePreview() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else if previewURLs.isEmpty {
            NSSound.beep()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = previewURLs
        guard index >= 0 && index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    /// While the preview is open, Up and Down keep moving through the table.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown && (event.keyCode == 125 || event.keyCode == 126) {
            table.keyDown(with: event)
            return true
        }
        return false
    }

    // MARK: Actions

    @objc func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Give to the cat"
        guard panel.runModal() == .OK else { return }
        // Files land in the folder being viewed (the top level in the flat views).
        Stash.shared.importParent = currentFolderID
        defer { Stash.shared.importParent = nil }
        if let onAdd = onAdd {
            onAdd(panel.urls)
        } else {
            for u in panel.urls { Stash.shared.add(u, moveOriginal: false) }
        }
    }

    /// A single folder opens inside the window (like Finder); files open in their own app.
    @objc func openSelected() {
        let items = selected()
        if items.count == 1, items[0].isFolder {
            navigate(to: .folder(items[0].id))
            return
        }
        for it in items where !it.isFolder {
            do {
                NSWorkspace.shared.open(try Stash.shared.openableURL(for: it))
            } catch {
                showError(error)
                break
            }
        }
    }

    private func showError(_ error: Error) {
        let a = NSAlert()
        a.messageText = "I couldn't do that."
        a.informativeText = error.localizedDescription
        a.alertStyle = .warning
        a.runModal()
    }

    /// Locks the selected items, or unlocks them if they are all locked already.
    @objc func togglePrivate() {
        let items = selected()
        if items.isEmpty { return }
        let lock = !items.allSatisfy { $0.isPrivate }

        if lock {
            if items.contains(where: { $0.isFolder }) {
                showError(StashCryptoError.foldersNotSupported)
                return
            }
            let key = "privateWarningShown"
            if !UserDefaults.standard.bool(forKey: key) {
                let a = NSAlert()
                a.messageText = "Lock this item?"
                a.informativeText = "Locked items are encrypted with your MoonCat password. MoonCat asks for it once per launch. If you forget it, or delete vault.json, locked items can't be recovered."
                a.addButton(withTitle: "Lock")
                a.addButton(withTitle: "Cancel")
                guard a.runModal() == .alertFirstButtonReturn else { return }
                UserDefaults.standard.set(true, forKey: key)
            }
        }

        for it in items where it.isPrivate != lock {
            do {
                try Stash.shared.setPrivate(id: it.id, lock)
                thumbCache.removeObject(forKey: it.id as NSString)
                iconCache.removeObject(forKey: it.id as NSString)
            } catch {
                showError(error)
                break
            }
        }
        reload()
    }

    private func updatePrivateButton() {
        let sel = selected()
        privateButton?.isEnabled = !sel.isEmpty
        privateButton?.title = (!sel.isEmpty && sel.allSatisfy { $0.isPrivate }) ? "Unlock" : "Lock"
    }

    @objc func revealSelected() {
        let urls = selected().filter { !$0.isFolder }.map { Stash.shared.url(for: $0) }
        if urls.isEmpty {
            NSWorkspace.shared.open(Stash.shared.root)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    @objc func saveCopy() {
        let items = selected()
        if items.isEmpty { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        panel.message = "Where should I put the copy?"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        var saved: [URL] = []
        for it in items {
            do {
                saved.append(try Stash.shared.materialize(it, into: dir))
            } catch {
                showError(error)
                break
            }
        }
        if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
    }

    @objc func deleteSelected() {
        let items = selected()
        if items.isEmpty { return }
        let a = NSAlert()
        if items.count == 1 {
            a.messageText = "Delete “\(items[0].name)” from the Treasure Box?"
        } else {
            a.messageText = "Delete \(items.count) items from the Treasure Box?"
        }
        let hasFolder = items.contains { $0.isFolder }
        a.informativeText = (hasFolder ? "Folders are deleted together with everything inside them. " : "")
            + "The stored copy is removed for good. Files elsewhere on your Mac aren't touched."
        a.alertStyle = .warning
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for it in items { Stash.shared.remove(it) }
        reload()
    }

    // MARK: Finder-style actions

    @objc func newFolder() {
        if !inFolderView { navigate(to: .folder(nil)) }
        do {
            let f = try Stash.shared.createFolder(named: "untitled folder", in: currentFolderID)
            reload()
            if let row = shown.firstIndex(where: { $0.id == f.id }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
                renameSelected()
            }
        } catch {
            showError(error)
        }
    }

    @objc func renameSelected() {
        guard selected().count == 1 else { NSSound.beep(); return }
        let col = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        if col >= 0 { table.editColumn(col, row: table.selectedRow, with: nil, select: true) }
    }

    @objc func duplicateSelected() {
        let items = selected()
        if items.isEmpty { return }
        do {
            for it in items { try Stash.shared.copy(ids: [it.id], to: it.parentID) }
        } catch {
            showError(error)
        }
        reload()
    }

    private func writeClipboard(cut: Bool) {
        let ids = selected().map { $0.id }
        if ids.isEmpty { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString((cut ? "cut|" : "copy|") + ids.joined(separator: ","), forType: stashMoveType)
    }

    @objc func copySelection() { writeClipboard(cut: false) }
    @objc func cutSelection() { writeClipboard(cut: true) }

    @objc func pasteHere() {
        guard case .folder(let target) = location else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        if let s = pb.string(forType: stashMoveType) {
            let parts = s.components(separatedBy: "|")
            guard parts.count == 2 else { return }
            let ids = parts[1].components(separatedBy: ",").filter { !$0.isEmpty }
            do {
                if parts[0] == "cut" {
                    try Stash.shared.move(ids: ids, to: target)
                    pb.clearContents()
                } else {
                    try Stash.shared.copy(ids: ids, to: target)
                }
            } catch {
                showError(error)
            }
            reload()
        } else if let urls = pb.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for u in urls { Stash.shared.add(u, moveOriginal: false, parent: target) }
            reload()
        } else {
            NSSound.beep()
        }
    }

    /// Return renames, ⌘⌫ deletes, ⌘↓ opens, ⌘↑ goes up, ⌘[ ⌘] go back/forward, ⌘C ⌘X ⌘V ⌘D, ⇧⌘N.
    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods.isEmpty && (event.keyCode == 36 || event.keyCode == 76) {
            renameSelected()
            return true
        }
        if mods == .command {
            switch (event.keyCode, ch) {
            case (51, _): deleteSelected(); return true
            case (125, _), (_, "o"): openSelected(); return true
            case (126, _): goUp(); return true
            case (_, "["): goBack(); return true
            case (_, "]"): goForward(); return true
            case (_, "c"): copySelection(); return true
            case (_, "x"): cutSelection(); return true
            case (_, "v"): pasteHere(); return true
            case (_, "d"): duplicateSelected(); return true
            default: return false
            }
        }
        if mods == [.command, .shift] && ch == "n" {
            newFolder()
            return true
        }
        return false
    }

    private func buildContextMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        add("Open", #selector(openSelected))
        add("Rename", #selector(renameSelected))
        add("Duplicate", #selector(duplicateSelected))
        m.addItem(.separator())
        add("Copy", #selector(copySelection))
        add("Cut", #selector(cutSelection))
        add("Paste", #selector(pasteHere))
        m.addItem(.separator())
        add("New Folder", #selector(newFolder))
        add("Show in Finder", #selector(revealSelected))
        m.addItem(.separator())
        add("Delete…", #selector(deleteSelected))
        return m
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let n = selected().count
        switch item.action {
        case #selector(renameSelected): return n == 1
        case #selector(openSelected), #selector(duplicateSelected), #selector(copySelection),
             #selector(cutSelection), #selector(revealSelected), #selector(deleteSelected):
            return n > 0
        case #selector(pasteHere):
            guard case .folder = location else { return false }
            let pb = NSPasteboard.general
            return pb.string(forType: stashMoveType) != nil || pb.canReadObject(forClasses: [NSURL.self],
                                                                                options: [.urlReadingFileURLsOnly: true])
        default: return true
        }
    }
}

// MARK: - Icon and column views

final class ColumnNode: NSObject {
    let id: String?
    init(_ id: String?) { self.id = id }
}

final class StashIconItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("StashIconItem")
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        icon.frame = NSRect(x: 18, y: 34, width: 64, height: 64)
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.frame = NSRect(x: 2, y: 2, width: 96, height: 30)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 11)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        v.addSubview(icon)
        v.addSubview(label)
        view = v
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil
        }
    }

    func configure(image: NSImage, name: String) {
        icon.image = image
        label.stringValue = name
    }
}

extension StashWindowController: NSCollectionViewDataSource, NSCollectionViewDelegate, NSBrowserDelegate {
    /// Shows the scroll view that matches the chosen mode.
    fileprivate func applyViewMode() {
        listScroll?.isHidden = viewMode != .list
        iconScroll.isHidden = viewMode != .icon
        browser.isHidden = viewMode != .column
        viewSwitch.selectedSegment = viewMode.rawValue
    }

    fileprivate func refreshViews(selecting rows: IndexSet) {
        applyViewMode()
        switch viewMode {
        case .list:
            break
        case .icon:
            collection.reloadData()
            collection.selectionIndexPaths = Set(rows.map { IndexPath(item: $0, section: 0) })
        case .column:
            colNodes.removeAll()
            browser.loadColumnZero()
        }
    }

    // Icons. The hidden table keeps the selection, so the editor, Delete, Lock and the rest work unchanged.

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        return shown.count
    }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: StashIconItem.id, for: ip)
        if let cell = item as? StashIconItem, ip.item < shown.count {
            let it = shown[ip.item]
            cell.configure(image: thumbnail(for: it), name: it.name)
        }
        return item
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncIconSelection() }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncIconSelection() }

    fileprivate func syncIconSelection() {
        let rows = IndexSet(collection.selectionIndexPaths.map { $0.item }.filter { $0 < shown.count })
        table.selectRowIndexes(rows, byExtendingSelection: false)
    }

    @objc fileprivate func iconDoubleClicked() { openSelected() }

    // Columns. The first column is what the list would show; folders open into the next column.

    fileprivate func columnNode(_ id: String?) -> ColumnNode {
        if let n = colNodes[id ?? ""] { return n }
        let n = ColumnNode(id)
        colNodes[id ?? ""] = n
        return n
    }

    private func columnChildren(_ node: ColumnNode) -> [StashItem] {
        guard let id = node.id else { return shown }
        return sortedItems(Stash.shared.children(of: id))
    }

    var columnSelection: [StashItem] {
        return browser.selectionIndexPaths.compactMap { ip in
            (browser.item(at: ip) as? ColumnNode)?.id.flatMap { Stash.shared.item($0) }
        }
    }

    func rootItem(for browser: NSBrowser) -> Any? { return columnNode(nil) }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? ColumnNode else { return 0 }
        return columnChildren(n).count
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? ColumnNode else { return columnNode(nil) }
        let list = columnChildren(n)
        return columnNode(index < list.count ? list[index].id : nil)
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        guard let id = (item as? ColumnNode)?.id else { return false }
        return Stash.shared.item(id)?.isFolder != true
    }

    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        guard let id = (item as? ColumnNode)?.id else { return "" }
        return Stash.shared.item(id)?.name ?? ""
    }

    func browserSelectionDidChange(_ browser: NSBrowser) {
        commitEdits()
        loadEditor()
        updatePrivateButton()
    }

    @objc fileprivate func browserDoubleClicked() { openSelected() }
}
