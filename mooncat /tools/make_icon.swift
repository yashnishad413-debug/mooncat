// Draws the MoonCat app icon and writes a .iconset folder.
// Usage: swift tools/make_icon.swift [output-folder]      (default: MoonCat.iconset)
// Normally run through tools/make_icon.sh, which also turns the folder into Resources/AppIcon.icns.

import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MoonCat.iconset",
                 isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Draws the icon on a 1024 x 1024 canvas (origin bottom-left). Everything is scaled by the caller.
func drawIcon() {
    let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    // macOS-style tile: a rounded square with a little margin.
    let tile = full.insetBy(dx: 52, dy: 52)
    let clip = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2237, yRadius: tile.width * 0.2237)

    NSGraphicsContext.saveGraphicsState()
    clip.addClip()

    // Night sky.
    let sky = NSGradient(colors: [NSColor(calibratedRed: 0.08, green: 0.07, blue: 0.22, alpha: 1),
                                  NSColor(calibratedRed: 0.30, green: 0.18, blue: 0.48, alpha: 1)])!
    sky.draw(in: tile, angle: 70)

    // A few stars.
    NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
    for (x, y, r) in [(250.0, 820.0, 9.0), (420.0, 880.0, 6.0), (780.0, 800.0, 8.0), (860.0, 620.0, 6.0),
                      (170.0, 600.0, 6.0), (600.0, 900.0, 7.0)] {
        NSBezierPath(ovalIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
    }

    // Crescent moon: a disc with a second disc cut out of it.
    let moon = NSBezierPath(ovalIn: CGRect(x: 380, y: 380, width: 470, height: 470))
    moon.append(NSBezierPath(ovalIn: CGRect(x: 505, y: 440, width: 440, height: 440)))
    moon.windingRule = .evenOdd
    NSColor(calibratedRed: 0.99, green: 0.93, blue: 0.72, alpha: 1).setFill()
    moon.fill()

    // The cat: sitting on the bottom edge, seen from behind-front, as a soft silhouette.
    let ink = NSColor(calibratedRed: 0.10, green: 0.08, blue: 0.16, alpha: 1)
    ink.setFill()

    let body = NSBezierPath()
    body.move(to: CGPoint(x: 250, y: 90))
    body.curve(to: CGPoint(x: 330, y: 400), controlPoint1: CGPoint(x: 220, y: 230), controlPoint2: CGPoint(x: 260, y: 340))
    body.line(to: CGPoint(x: 700, y: 400))
    body.curve(to: CGPoint(x: 790, y: 90), controlPoint1: CGPoint(x: 780, y: 340), controlPoint2: CGPoint(x: 810, y: 230))
    body.close()
    body.fill()

    // Head and ears.
    NSBezierPath(ovalIn: CGRect(x: 290, y: 330, width: 440, height: 360)).fill()
    for flip in [false, true] {
        let ear = NSBezierPath()
        let sign: CGFloat = flip ? -1 : 1
        let cx: CGFloat = 510
        ear.move(to: CGPoint(x: cx - sign * 190, y: 560))
        ear.line(to: CGPoint(x: cx - sign * 160, y: 790))
        ear.line(to: CGPoint(x: cx - sign * 20, y: 660))
        ear.close()
        ear.fill()
    }

    // Eyes and nose.
    NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: 395, y: 475, width: 70, height: 84)).fill()
    NSBezierPath(ovalIn: CGRect(x: 555, y: 475, width: 70, height: 84)).fill()
    ink.setFill()
    NSBezierPath(ovalIn: CGRect(x: 422, y: 487, width: 18, height: 58)).fill()
    NSBezierPath(ovalIn: CGRect(x: 582, y: 487, width: 18, height: 58)).fill()
    NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.65, alpha: 1).setFill()
    let nose = NSBezierPath()
    nose.move(to: CGPoint(x: 490, y: 450))
    nose.line(to: CGPoint(x: 530, y: 450))
    nose.line(to: CGPoint(x: 510, y: 425))
    nose.close()
    nose.fill()

    NSGraphicsContext.restoreGraphicsState()
}

func png(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    gc.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    gc.imageInterpolation = .high
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let files: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, px) in files {
    guard let data = png(pixels: px) else {
        FileHandle.standardError.write(Data("Could not draw \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outDir.appendingPathComponent(name))
}
print("Wrote \(files.count) images to \(outDir.path)")
