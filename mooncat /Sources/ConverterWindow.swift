import AppKit

// MARK: - Drop target

final class ConverterDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onClick: (() -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: Theme.cardRadius, yRadius: Theme.cardRadius)
        (highlighted ? Theme.accent.withAlphaComponent(0.14) : Theme.surface).setFill()
        path.fill()
        path.lineWidth = highlighted ? 2 : 1.25
        path.setLineDash([7, 5], count: 2, phase: 0)
        (highlighted ? Theme.accent : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()

        let art = ConverterDropView.picture
        let para = NSMutableParagraphStyle()
        para.alignment = art == nil ? .center : .left
        let title = NSAttributedString(string: highlighted ? "Let go to add" : "Drop files here", attributes: [
            .font: Theme.font(15, .semibold, rounded: true), .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
        let sub = NSAttributedString(string: "or click to choose. Pictures, PDFs, documents, tables, sound and video.", attributes: [
            .font: Theme.font(12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para])

        if let img = art {
            let ih = bounds.height - 18
            let iw = ih * img.size.width / max(1, img.size.height)
            img.draw(in: NSRect(x: 16, y: 9, width: iw, height: ih))
            let tx = 16 + iw + 18
            let tw = max(60, bounds.width - tx - 18)
            let th = title.size().height
            let sb = sub.boundingRect(with: NSSize(width: tw, height: 80), options: [.usesLineFragmentOrigin])
            let total = th + 4 + ceil(sb.height)
            var y = bounds.midY + total / 2
            title.draw(in: NSRect(x: tx, y: y - th, width: tw, height: th))
            y -= th + 4
            sub.draw(with: NSRect(x: tx, y: y - ceil(sb.height), width: tw, height: ceil(sb.height)),
                     options: [.usesLineFragmentOrigin])
            return
        }

        let th = title.size().height, sh = sub.size().height
        let iconSize: CGFloat = 30
        let total = iconSize + 8 + th + 3 + sh
        var y = bounds.midY + total / 2
        if let base = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 24, weight: .light)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Theme.accent]))
            if let img = base.withSymbolConfiguration(cfg) {
                let sz = img.size
                img.draw(in: NSRect(x: bounds.midX - sz.width / 2, y: y - iconSize + (iconSize - sz.height) / 2,
                                    width: sz.width, height: sz.height))
            }
        }
        y -= iconSize + 8
        title.draw(in: NSRect(x: 8, y: y - th, width: bounds.width - 16, height: th))
        y -= th + 3
        sub.draw(in: NSRect(x: 8, y: y - sh, width: bounds.width - 16, height: sh))
    }

    private static let picture: NSImage? = Art.image("converter_drop")

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { return true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty { return false }
        onDrop?(urls)
        return true
    }
}

// MARK: - Window

final class ConvertItem {
    let url: URL
    let fmt: Fmt?
    var status: String
    init(url: URL) {
        self.url = url
        self.fmt = Fmt.from(url: url)
        self.status = fmt == nil ? "Not supported" : "Ready"
    }
}

/// "Convert Files…": drop files, pick a format, press Convert.
final class ConverterWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = ConverterWindowController()

    private let window: NSWindow
    private let dropZone = ConverterDropView(frame: .zero)
    private let table = NSTableView()
    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let savePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualitySlider = NSSlider(value: 0.9, minValue: 0.3, maxValue: 1.0, target: nil, action: nil)
    private let qualityRow = NSStackView()
    private let convertButton = NSButton(title: "Convert", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    private var items: [ConvertItem] = []
    private var targetList: [Fmt] = []
    private var customFolder: URL?
    private var running = false
    private var lastOutputs: [URL] = []

    private static let targetKey = "converterLastTarget"

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Convert Files"
        Theme.style(window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 560, height: 700)
        build()
        refresh()
    }

    // MARK: Showing

    func show() {
        activateApp()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func showAndAdd(_ urls: [URL]) {
        add(urls)
        show()
    }

    // MARK: Layout

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .left
        l.font = Theme.font(13, .medium)
        l.textColor = .secondaryLabelColor
        l.widthAnchor.constraint(equalToConstant: 84).isActive = true
        return l
    }

    private func build() {
        guard let content = window.contentView else { return }

        dropZone.onDrop = { [weak self] urls in self?.add(urls) }
        dropZone.onClick = { [weak self] in self?.chooseFiles() }
        dropZone.heightAnchor.constraint(equalToConstant: 140).isActive = true

        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = 28
        table.gridStyleMask = []
        table.backgroundColor = .clear
        for (id, title, width) in [("file", "File", 230.0), ("type", "Type", 130.0), ("result", "Result", 180.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = CGFloat(width)
            col.minWidth = 70
            table.addTableColumn(col)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        targetPopup.target = self
        targetPopup.action = #selector(targetChanged)
        targetPopup.autoenablesItems = false
        let targetRow = NSStackView(views: [label("Convert to:"), targetPopup])
        targetRow.spacing = 8

        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        qualitySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        qualityRow.setViews([label("Quality:"), qualitySlider], in: .leading)
        qualityRow.spacing = 8

        savePopup.addItems(withTitles: ["Next to the original", "Downloads folder", "Choose folder…"])
        savePopup.target = self
        savePopup.action = #selector(saveChanged)
        let saveRow = NSStackView(views: [label("Save to:"), savePopup])
        saveRow.spacing = 8

        convertButton.target = self
        convertButton.action = #selector(convertAction)
        Theme.primary(convertButton)
        for (b, sel) in [(removeButton, #selector(removeSelected)), (clearButton, #selector(clearAll)),
                         (revealButton, #selector(reveal))] {
            b.target = self
            b.action = sel
            b.bezelStyle = .rounded
        }
        let flex = NSView()
        flex.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [removeButton, clearButton, revealButton, flex, convertButton])
        buttons.spacing = 8

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        statusLabel.font = Theme.font(12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3

        let header = Theme.header(symbol: "arrow.triangle.2.circlepath", title: "Convert",
                                  subtitle: "Drop a file, pick a format. Nothing leaves your Mac.")

        let options = NSStackView(views: [targetRow, qualityRow, saveRow])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 12
        let optionsCard = Theme.card(options)
        let filesCard = Theme.card(scroll, padding: 6)

        let stack = NSStackView(views: [header, dropZone, filesCard, optionsCard, buttons, progress, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.distribution = .fill
        filesCard.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        stack.setCustomSpacing(18, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Theme.pad),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.pad),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Theme.pad),
            dropZone.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filesCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            optionsCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    // MARK: Adding files

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        if running { return }
        for u in urls where !items.contains(where: { $0.url == u }) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
                items.append(ConvertItem(url: u))
            }
        }
        lastOutputs = []
        refresh()
    }

    // MARK: State

    private var knownItems: [ConvertItem] { return items.filter { $0.fmt != nil } }

    /// Formats every added file can become.
    private func commonTargets() -> [Fmt] {
        let known = knownItems.compactMap { $0.fmt }
        guard let first = known.first else { return [] }
        var common = Fmt.targets(from: first)
        for f in known.dropFirst() {
            let t = Fmt.targets(from: f)
            common = common.filter { t.contains($0) }
        }
        return common
    }

    private var selectedTarget: Fmt? {
        let i = targetPopup.indexOfSelectedItem
        return i >= 0 && i < targetList.count ? targetList[i] : nil
    }

    private func refresh() {
        let previous = selectedTarget ?? Fmt(rawValue: UserDefaults.standard.string(forKey: Self.targetKey) ?? "")
        targetList = commonTargets()
        targetPopup.removeAllItems()
        for f in targetList {
            var title = "\(f.label) (.\(f.ext))"
            let ok = Converter.canWrite(f)
            if !ok { title += " — not available on this Mac" }
            targetPopup.addItem(withTitle: title)
            targetPopup.lastItem?.isEnabled = ok
        }
        if let p = previous, let idx = targetList.firstIndex(of: p), Converter.canWrite(p) {
            targetPopup.selectItem(at: idx)
        } else if let idx = targetList.firstIndex(where: { Converter.canWrite($0) }) {
            targetPopup.selectItem(at: idx)
        }
        table.reloadData()
        updateControls()

        if items.isEmpty {
            statusLabel.stringValue = "Add some files to begin."
        } else if knownItems.isEmpty {
            statusLabel.stringValue = "None of these file types can be converted."
        } else if targetList.isEmpty {
            statusLabel.stringValue = "These files have no format in common. Convert them in separate batches."
        } else {
            let skipped = items.count - knownItems.count
            statusLabel.stringValue = skipped > 0 ? "\(skipped) file(s) will be skipped: unsupported type." : ""
        }
    }

    private func updateControls() {
        let t = selectedTarget
        qualityRow.isHidden = !(t == .jpg || t == .heic || t == .jp2)
        convertButton.isEnabled = !running && t != nil && !knownItems.isEmpty
        removeButton.isEnabled = !running && table.selectedRow >= 0
        clearButton.isEnabled = !running && !items.isEmpty
        revealButton.isEnabled = !lastOutputs.isEmpty
        targetPopup.isEnabled = !running
        savePopup.isEnabled = !running
    }

    // MARK: Actions

    @objc private func targetChanged() { updateControls() }
    @objc private func qualityChanged() {}

    @objc private func saveChanged() {
        if savePopup.indexOfSelectedItem == 2 {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Save Here"
            if panel.runModal() == .OK, let u = panel.url {
                customFolder = u
                savePopup.item(at: 2)?.title = "Folder: " + u.lastPathComponent
            } else if customFolder == nil {
                savePopup.selectItem(at: 0)
            }
        }
    }

    @objc private func removeSelected() {
        if running { return }
        let rows = table.selectedRowIndexes
        items = items.enumerated().filter { !rows.contains($0.offset) }.map { $0.element }
        refresh()
    }

    @objc private func clearAll() {
        if running { return }
        items = []
        lastOutputs = []
        refresh()
    }

    @objc private func reveal() {
        if !lastOutputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(lastOutputs) }
    }

    private func outputDir(for src: URL) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        switch savePopup.indexOfSelectedItem {
        case 1: return downloads
        case 2: return customFolder ?? downloads
        default:
            let dir = src.deletingLastPathComponent()
            return FileManager.default.isWritableFile(atPath: dir.path) ? dir : downloads
        }
    }

    @objc private func convertAction() {
        guard !running, let target = selectedTarget else { return }
        UserDefaults.standard.set(target.rawValue, forKey: Self.targetKey)
        let todo = knownItems
        for it in items where it.fmt == nil { it.status = "Skipped" }
        running = true
        lastOutputs = []
        progress.doubleValue = 0
        progress.maxValue = Double(max(todo.count, 1))
        statusLabel.stringValue = "Converting…"
        for it in todo { it.status = "Waiting" }
        table.reloadData()
        updateControls()
        let options = ConvertOptions(quality: qualitySlider.doubleValue)

        Task { @MainActor in
            var done = 0, failed = 0
            for item in todo {
                item.status = "Converting…"
                self.table.reloadData()
                do {
                    let outs = try await Converter.convert(item.url, to: target, into: self.outputDir(for: item.url), options: options)
                    self.lastOutputs += outs
                    item.status = outs.count == 1 ? "Done: " + outs[0].lastPathComponent : "Done: \(outs.count) files"
                    done += 1
                } catch {
                    item.status = "Failed: " + error.localizedDescription
                    Log.error("Convert \(item.url.pathExtension)→\(target.ext) failed: \(error.localizedDescription)")
                    failed += 1
                }
                self.progress.doubleValue += 1
                self.table.reloadData()
            }
            self.running = false
            var msg = "Converted \(done) file\(done == 1 ? "" : "s")."
            if failed > 0 { msg += " \(failed) failed; see the Result column." }
            self.statusLabel.stringValue = msg
            self.updateControls()
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { return items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count, let col = tableColumn else { return nil }
        let item = items[row]
        let text: String
        switch col.identifier.rawValue {
        case "file": text = item.url.lastPathComponent
        case "type": text = item.fmt?.label ?? "." + item.url.pathExtension
        default: text = item.status
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = text
        if col.identifier.rawValue == "result" {
            if item.status.hasPrefix("Failed") { field.textColor = .systemRed }
            else if item.status.hasPrefix("Done") { field.textColor = .systemGreen }
            else { field.textColor = .secondaryLabelColor }
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
}
