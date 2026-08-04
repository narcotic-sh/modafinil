import Foundation

enum BatterySleepThreshold: Int, CaseIterable {
    case never = 0
    case fivePercent = 5
    case tenPercent = 10
    case fifteenPercent = 15
    case twentyPercent = 20
    case twentyFivePercent = 25
    case thirtyPercent = 30
    case fortyPercent = 40
    case fiftyPercent = 50

    var percentage: Int? {
        guard rawValue > 0 else { return nil }
        return rawValue
    }

    var title: String {
        percentage.map { "\($0)%" } ?? "Never"
    }

    static func savedValue(
        defaults: UserDefaults = .standard,
        key: String
    ) -> BatterySleepThreshold {
        BatterySleepThreshold(rawValue: defaults.integer(forKey: key)) ?? .never
    }
}
