import AppKit
import CoreGraphics

extension Settings {
    /// Let her sit on the top edge of other apps' windows. Off by default.
    var perchEnabled: Bool {
        get { return UserDefaults.standard.bool(forKey: "perchEnabled") }
        set { storeExtra(newValue, "perchEnabled") }
    }
    static let perchDefaults: [String: Any] = ["perchEnabled": false]
}

struct PerchSpot {
    let windowID: CGWindowID
    /// Window frame in AppKit screen coordinates (origin bottom-left of the primary display).
    let frame: CGRect
    var topY: CGFloat { return frame.maxY }
}

/// Finds window tops to sit on. It reads ONLY window bounds, owner and layer through
/// CGWindowListCopyWindowInfo; it never reads window titles or contents. Titles are what need the
/// Screen Recording permission, bounds do not, so no permission prompt appears.
final class Perch {
    static let shared = Perch()
    private init() {}

    private var spots: [PerchSpot] = []
    private var fetchedAt: CFTimeInterval = 0

    /// Windows from the front of the screen to the back, cached for half a second.
    private func refreshIfNeeded() {
        let now = CACurrentMediaTime()
        if now - fetchedAt < 0.5 { return }
        fetchedAt = now
        spots = Perch.collect()
    }

    /// CoreGraphics gives window bounds with the origin at the TOP-left of the primary display and
    /// y growing downward. AppKit uses the BOTTOM-left of the primary display with y growing upward:
    ///     appKitY = primaryHeight - cgY - height
    /// x is the same in both. This holds on every display, because both systems share one global
    /// space that is anchored to the primary display.
    private static func collect() -> [PerchSpot] {
        guard let primary = NSScreen.screens.first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let primaryHeight = primary.frame.height
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var out: [PerchSpot] = []

        for w in info {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = w[kCGWindowNumber as String] as? UInt32,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = (b["X"] as? NSNumber)?.doubleValue,
                  let y = (b["Y"] as? NSNumber)?.doubleValue,
                  let width = (b["Width"] as? NSNumber)?.doubleValue,
                  let height = (b["Height"] as? NSNumber)?.doubleValue else { continue }
            if (w[kCGWindowAlpha as String] as? Double ?? 1) < 0.1 { continue }
            if width < 200 || height < 120 { continue }

            let frame = CGRect(x: x, y: primaryHeight - y - height, width: width, height: height)
            // Skip full-screen windows (nothing to sit on).
            if NSScreen.screens.contains(where: { $0.frame.equalTo(frame) }) { continue }
            out.append(PerchSpot(windowID: id, frame: frame))
        }
        return out
    }

    /// Windows that are in front of `spot` (earlier in the list) and cover the point just under its top edge.
    private func isCovered(_ spot: PerchSpot, atX x: CGFloat) -> Bool {
        for s in spots {
            if s.windowID == spot.windowID { return false }
            if s.frame.contains(CGPoint(x: x, y: spot.topY - 2)) { return true }
        }
        return false
    }

    /// A window top near her feet that she can step onto, if any.
    /// - feetY: her feet in AppKit coordinates (the same as PetController.pos.y)
    func spot(nearX x: CGFloat, feetY: CGFloat) -> PerchSpot? {
        refreshIfNeeded()
        var best: PerchSpot?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for s in spots {
            let margin: CGFloat = 24
            guard x >= s.frame.minX + margin, x <= s.frame.maxX - margin else { continue }
            let d = abs(s.topY - feetY)
            if d > 50 || d >= bestDist { continue }
            if isCovered(s, atX: x) { continue }
            best = s
            bestDist = d
        }
        return best
    }

    /// The current frame of a window she is already sitting on (nil if it closed or went off screen).
    func spot(windowID: CGWindowID) -> PerchSpot? {
        refreshIfNeeded()
        return spots.first { $0.windowID == windowID }
    }

    /// Eases `current` toward `target`, at most `maxSpeed` points per second.
    static func eased(current: CGFloat, target: CGFloat, dt: CGFloat, maxSpeed: CGFloat = 600) -> CGFloat {
        let diff = target - current
        let step = maxSpeed * dt
        if abs(diff) <= step { return target }
        return current + (diff > 0 ? step : -step)
    }
}
