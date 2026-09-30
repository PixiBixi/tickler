import Foundation

/// `--for` values: a positive integer followed by m, h or d.
enum SnoozeDuration {
    static func parse(_ value: String) -> TimeInterval? {
        guard let match = value.wholeMatch(of: /(\d{1,6})([mhd])/), let amount = Int(match.1), amount > 0 else { return nil }
        let unit: Double = switch match.2 {
        case "m": 60
        case "h": 3600
        default: 86400
        }
        return Double(amount) * unit
    }
}
