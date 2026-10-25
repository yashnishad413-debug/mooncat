import Foundation
import IOKit.ps

extension Settings {
    /// Below this charge (and not plugged in) she gets sleepy.
    var lowBatteryPercent: Int {
        get { return UserDefaults.standard.integer(forKey: "lowBatteryPercent") }
        set { storeExtra(newValue, "lowBatteryPercent") }
    }

    static let systemDefaults: [String: Any] = [
        "lowBatteryPercent": 20,
        "moodEnabled": true
    ]
}

// MARK: - Downloads

/// Notices when a download in ~/Downloads has finished. A file counts as finished when its name
/// is not a browser's partial-download name and its size has stopped changing for 2 seconds.
/// Files that were already there when MoonCat started are ignored.
/// macOS asks for permission to read the Downloads folder the first time (see Info.plist).
final class DownloadsWatcher {
    static let shared = DownloadsWatcher()

    /// Called on the main thread, once per burst of finished downloads.
    var onFinished: (() -> Void)?

    private let queue = DispatchQueue(label: "com.yash.mooncat.downloads")
    private var source: DispatchSourceFileSystemObject?
    private var rescan: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?

    private var seen: [URL: (size: Int64, since: CFAbsoluteTime)] = [:]
    private var finished = Set<URL>()
    private var baselineDone = false
    private let partialExtensions: Set<String> = ["crdownload", "download", "part", "opdownload", "partial", "tmp"]

    private init() {}

    func start() {
        guard source == nil,
              let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        s.setEventHandler { [weak self] in self?.scan() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        rescan = t
    }

    func stop() {
        source?.cancel()
        source = nil
        rescan?.cancel()
        rescan = nil
    }

    /// Runs on `queue`.
    private func scan() {
        guard let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        var present = Set<URL>()

        for url in contents {
            if partialExtensions.contains(url.pathExtension.lowercased()) { continue }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory != true,
                  let size = values.fileSize else { continue }
            present.insert(url)
            let size64 = Int64(size)

            if let info = seen[url] {
                if info.size != size64 {
                    seen[url] = (size64, now)
                    finished.remove(url)
                } else if now - info.since >= 2.0, !finished.contains(url) {
                    finished.insert(url)
                    fileFinished()
                }
            } else {
                seen[url] = (size64, now)
                // The very first look at the folder only records what is already there.
                if !baselineDone { finished.insert(url) }
            }
        }
        baselineDone = true

        for url in Array(seen.keys) where !present.contains(url) {
            seen.removeValue(forKey: url)
            finished.remove(url)
        }
    }

    private func fileFinished() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.onFinished?() }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 3.0, execute: work)
    }
}

// MARK: - Battery

/// Reads the internal battery once a minute (desktop Macs simply have none).
final class BatteryWatcher {
    static let shared = BatteryWatcher()

    private(set) var percent: Int?
    private(set) var isCharging = false
    private(set) var onACPower = true
    /// Low charge, and not plugged in.
    private(set) var isLow = false

    private var timer: Timer?

    private init() {}

    func start() {
        poll()
        timer?.invalidate()
        let t = Timer(timeInterval: 60, target: self, selector: #selector(pollTick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func pollTick() { poll() }

    private func poll() {
        guard let infoRef = IOPSCopyPowerSourcesInfo() else { return }
        let info = infoRef.takeRetainedValue()
        guard let listRef = IOPSCopyPowerSourcesList(info) else { return }
        let sources = listRef.takeRetainedValue() as [CFTypeRef]

        for source in sources {
            guard let descRef = IOPSGetPowerSourceDescription(info, source) else { continue }
            guard let desc = descRef.takeUnretainedValue() as? [String: Any] else { continue }
            guard (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            let current = (desc[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
            let maximum = (desc[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 0
            guard maximum > 0 else { continue }

            let pct = Int((current / maximum * 100).rounded())
            percent = pct
            isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            onACPower = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            isLow = !onACPower && !isCharging && pct < Settings.shared.lowBatteryPercent
            return
        }
        // No internal battery found.
        percent = nil
        isLow = false
    }
}
