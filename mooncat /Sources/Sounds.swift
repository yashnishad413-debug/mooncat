import AppKit
import AVFoundation

/// Meow, purr and chime. The files are optional: if one is missing nothing plays and nothing breaks.
/// Looked for, in order: the app's Resources, Resources/sounds, and
/// ~/Library/Application Support/MoonCat/sounds (handy: drop your own files there, no rebuild needed).
final class Sounds {
    static let shared = Sounds()

    enum SoundName: String {
        case meow, purr, chime
    }

    private var players: [SoundName: AVAudioPlayer] = [:]
    private var purrPlayer: AVAudioPlayer?

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)
    }

    private func fileURL(for name: SoundName) -> URL? {
        let file = name.rawValue
        if let u = Bundle.main.url(forResource: file, withExtension: "wav") { return u }
        if let u = Bundle.main.url(forResource: file, withExtension: "wav", subdirectory: "sounds") { return u }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = support.appendingPathComponent("MoonCat/sounds/\(file).wav")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private var effectiveVolume: Float {
        let s = Settings.shared
        return s.soundsEnabled ? Float(s.soundVolume) : 0
    }

    private func player(for name: SoundName) -> AVAudioPlayer? {
        if let p = players[name] { return p }
        guard let url = fileURL(for: name), let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        p.prepareToPlay()
        players[name] = p
        return p
    }

    func play(_ name: SoundName) {
        guard Settings.shared.soundsEnabled, let p = player(for: name) else { return }
        p.currentTime = 0
        p.volume = effectiveVolume
        p.play()
    }

    func startPurr() {
        guard Settings.shared.soundsEnabled, purrPlayer == nil,
              let url = fileURL(for: .purr), let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.numberOfLoops = -1
        p.volume = effectiveVolume
        p.prepareToPlay()
        p.play()
        purrPlayer = p
    }

    func stopPurr() {
        purrPlayer?.stop()
        purrPlayer = nil
    }

    @objc private func settingsChanged(_ note: Notification) {
        let v = effectiveVolume
        for p in players.values { p.volume = v }
        purrPlayer?.volume = v
        if v == 0 { stopPurr() }
    }
}
