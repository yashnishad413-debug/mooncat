import AppKit

/// The menu bar icon: a crescent moon with two little cat ears. A template image, so macOS
/// colours it for light, dark and highlighted menu bars.
enum MenuBarIcon {
    static func template(size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width
            NSColor.black.setFill()

            // Crescent: a disc with a second disc cut out of it.
            let moon = NSBezierPath(ovalIn: CGRect(x: s * 0.10, y: s * 0.06, width: s * 0.76, height: s * 0.76))
            let cut = NSBezierPath(ovalIn: CGRect(x: s * 0.34, y: s * 0.20, width: s * 0.66, height: s * 0.66))
            moon.append(cut)
            moon.windingRule = .evenOdd
            moon.fill()

            // Two ears on top of the moon.
            let ear1 = NSBezierPath()
            ear1.move(to: CGPoint(x: s * 0.16, y: s * 0.62))
            ear1.line(to: CGPoint(x: s * 0.14, y: s * 0.96))
            ear1.line(to: CGPoint(x: s * 0.40, y: s * 0.78))
            ear1.close()
            ear1.fill()
            let ear2 = NSBezierPath()
            ear2.move(to: CGPoint(x: s * 0.50, y: s * 0.80))
            ear2.line(to: CGPoint(x: s * 0.72, y: s * 0.95))
            ear2.line(to: CGPoint(x: s * 0.72, y: s * 0.68))
            ear2.close()
            ear2.fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
