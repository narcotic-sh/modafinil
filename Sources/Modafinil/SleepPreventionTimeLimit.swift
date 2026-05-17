import Foundation

enum SleepPreventionTimeLimit: Int, CaseIterable {
    case none = 0
    #if MODAFINIL_TEST_TIMER_PRESET
    case thirtySeconds = 30
    #endif
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case twoHours = 7_200
    case fourHours = 14_400
    case sixHours = 21_600
    case twelveHours = 43_200
    case twentyFourHours = 86_400

    var duration: TimeInterval? {
        guard rawValue > 0 else { return nil }
        return TimeInterval(rawValue)
    }

    var title: String {
        switch self {
        case .none:
            return "No Limit"
        #if MODAFINIL_TEST_TIMER_PRESET
        case .thirtySeconds:
            return "30 Seconds"
        #endif
        case .fiveMinutes:
            return "5 Minutes"
        case .fifteenMinutes:
            return "15 Minutes"
        case .thirtyMinutes:
            return "30 Minutes"
        case .oneHour:
            return "1 Hour"
        case .twoHours:
            return "2 Hours"
        case .fourHours:
            return "4 Hours"
        case .sixHours:
            return "6 Hours"
        case .twelveHours:
            return "12 Hours"
        case .twentyFourHours:
            return "24 Hours"
        }
    }

    var shortTitle: String {
        switch self {
        case .none:
            return "No Limit"
        #if MODAFINIL_TEST_TIMER_PRESET
        case .thirtySeconds:
            return "30 secs"
        #endif
        case .fiveMinutes:
            return "5 mins"
        case .fifteenMinutes:
            return "15 mins"
        case .thirtyMinutes:
            return "30 mins"
        case .oneHour:
            return "1 hr"
        case .twoHours:
            return "2 hrs"
        case .fourHours:
            return "4 hrs"
        case .sixHours:
            return "6 hrs"
        case .twelveHours:
            return "12 hrs"
        case .twentyFourHours:
            return "24 hrs"
        }
    }

    static func savedValue(defaults: UserDefaults = .standard, key: String) -> SleepPreventionTimeLimit {
        SleepPreventionTimeLimit(rawValue: defaults.integer(forKey: key)) ?? .none
    }
}
