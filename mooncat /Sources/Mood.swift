import Foundation

enum Mood {
    case sleepy, normal, playful, calm
}

/// One mood value that only nudges existing behaviour (how soon she naps, how often she
/// pounces, how fast she walks). It is not a state machine and never touches the cat directly.
final class MoodCenter {
    static let shared = MoodCenter()
    private init() {}

    var currentMood: Mood {
        if !Settings.shared.moodEnabled { return .normal }
        if BatteryWatcher.shared.isLow { return .sleepy }
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<6: return .sleepy      // nap after midnight
        case 6..<12: return .playful    // stretch and play in the morning
        case 12..<18: return .normal
        default: return .calm           // calmer in the evening
        }
    }

    /// Multiplies the seconds of stillness before she falls asleep.
    var sleepDelayMultiplier: Double {
        switch currentMood {
        case .sleepy: return 0.5
        case .playful: return 1.5
        case .calm, .normal: return 1.0
        }
    }

    /// Multiplies how often she pounces (higher = more often).
    var playFrequencyMultiplier: Double {
        switch currentMood {
        case .sleepy: return 0.5
        case .playful: return 2.0
        case .calm: return 0.8
        case .normal: return 1.0
        }
    }

    /// Multiplies her walking speed.
    var speedMultiplier: Double {
        switch currentMood {
        case .sleepy: return 0.6
        case .playful: return 1.4
        case .calm: return 0.9
        case .normal: return 1.0
        }
    }
}

extension Settings {
    /// Let time of day and battery change her mood (on by default).
    var moodEnabled: Bool {
        get { return UserDefaults.standard.bool(forKey: "moodEnabled") }
        set { storeExtra(newValue, "moodEnabled") }
    }
}
