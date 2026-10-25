import AppKit
import ImageIO

// MARK: - Sprites

enum Facing { case right, left, front }

enum Pose: String {
    case look, follow, play, happy, sleep, curious, box
    /// Optional: sprites/yawn.png. Shown briefly before she falls asleep when the file exists.
    case yawn

    // Which way the artwork naturally faces.
    var facing: Facing {
        switch self {
        case .look, .follow: return .right
        case .play: return .left
        default: return .front
        }
    }
}

final class SpriteBank {
    static let shared = SpriteBank()
    private var cache: [String: CGImage] = [:]

    func image(_ name: String) -> CGImage? {
        if let c = cache[name] { return c }
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: name, withExtension: "png") {
            candidates.append(u)
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("sprites/\(name).png"))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("sprites/\(name).png"))

        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path),
               let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                cache[name] = img
                return img
            }
        }
        return nil
    }
}
