import AppKit

// MARK: - Window and view

final class PetWindow: NSPanel {
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }
}

final class CatView: NSView {
    weak var controller: PetController?
    private var downLocation = CGPoint.zero
    private var didDrag = false

    override var acceptsFirstResponder: Bool { return false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func mouseDown(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        downLocation = m
        didDrag = false
        controller?.beginDrag(mouse: m)
    }

    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        if gap(m, downLocation) > 4 { didDrag = true }
        if didDrag { controller?.drag(to: m) }
    }

    override func mouseUp(with event: NSEvent) {
        controller?.endDrag(clicked: !didDrag)
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showMenu(event: event, in: self)
    }

    // MARK: Files dropped onto the cat

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.fileHover(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.fileHover(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Real files, or text, links and images (turned into files by StashDrop).
        let urls = StashDrop.files(from: sender.draggingPasteboard)
        controller?.fileHover(false)
        if urls.isEmpty { return false }
        controller?.receiveFiles(urls)
        return true
    }
}
