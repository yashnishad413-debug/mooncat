import Foundation

/// Focus timer: work → short break → work … with a long break every few rounds.
final class Pomodoro {
    static let shared = Pomodoro()

    enum Phase { case off, work, shortBreak, longBreak }

    private(set) var phase: Phase = .off
    private(set) var remaining: TimeInterval = 0
    private var timer: Timer?
    private var roundCount = 0
    private var phaseEnd: Date?

    /// A phase started, or the timer was stopped (`.off`).
    var onPhaseChange: ((Phase) -> Void)?
    /// A running phase just finished (called with the phase that ended).
    var onPhaseEnd: ((Phase) -> Void)?
    /// Once a second while running, with the time left.
    var onTick: ((TimeInterval) -> Void)?

    private init() {}

    var isRunning: Bool { return phase != .off }

    func start() {
        guard phase == .off else { return }
        Notifier.shared.ensureAuthorized()
        roundCount = 0
        begin(.work)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        phase = .off
        remaining = 0
        phaseEnd = nil
        onPhaseChange?(.off)
        onTick?(0)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func minutes(for p: Phase) -> Int {
        let s = Settings.shared
        switch p {
        case .work: return max(1, s.pomodoroWorkMinutes)
        case .shortBreak: return max(1, s.pomodoroBreakMinutes)
        case .longBreak: return max(1, s.pomodoroLongBreakMinutes)
        case .off: return 0
        }
    }

    private func begin(_ newPhase: Phase) {
        phase = newPhase
        let length = TimeInterval(minutes(for: newPhase) * 60)
        remaining = length
        phaseEnd = Date().addingTimeInterval(length)
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        onPhaseChange?(newPhase)
        onTick?(remaining)
    }

    @objc private func tick() {
        guard phase != .off, let end = phaseEnd else { return }
        let left = end.timeIntervalSinceNow
        if left <= 0 {
            finishPhase()
        } else {
            remaining = left
            onTick?(left)
        }
    }

    private func finishPhase() {
        let ended = phase
        switch ended {
        case .work:
            Notifier.shared.post(title: "Focus session complete", body: "Time for a break.")
        case .shortBreak, .longBreak:
            Notifier.shared.post(title: "Break over", body: "Time to focus.")
        case .off:
            return
        }
        onPhaseEnd?(ended)

        switch ended {
        case .work:
            roundCount += 1
            if roundCount >= max(1, Settings.shared.pomodoroRoundsBeforeLongBreak) {
                roundCount = 0
                begin(.longBreak)
            } else {
                begin(.shortBreak)
            }
        case .shortBreak, .longBreak:
            begin(.work)
        case .off:
            break
        }
    }
}

// MARK: - Settings

extension Settings {
    var pomodoroWorkMinutes: Int {
        get { return UserDefaults.standard.integer(forKey: "pomodoroWorkMinutes") }
        set { storeExtra(newValue, "pomodoroWorkMinutes") }
    }
    var pomodoroBreakMinutes: Int {
        get { return UserDefaults.standard.integer(forKey: "pomodoroBreakMinutes") }
        set { storeExtra(newValue, "pomodoroBreakMinutes") }
    }
    var pomodoroLongBreakMinutes: Int {
        get { return UserDefaults.standard.integer(forKey: "pomodoroLongBreakMinutes") }
        set { storeExtra(newValue, "pomodoroLongBreakMinutes") }
    }
    var pomodoroRoundsBeforeLongBreak: Int {
        get { return UserDefaults.standard.integer(forKey: "pomodoroRoundsBeforeLongBreak") }
        set { storeExtra(newValue, "pomodoroRoundsBeforeLongBreak") }
    }

    static let pomodoroDefaults: [String: Any] = [
        "pomodoroWorkMinutes": 25,
        "pomodoroBreakMinutes": 5,
        "pomodoroLongBreakMinutes": 15,
        "pomodoroRoundsBeforeLongBreak": 4
    ]
}
