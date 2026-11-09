import Foundation

enum Format {
    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fk", Double(count) / 1_000)
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }

    static func rate(_ perSecond: Double?) -> String {
        guard let perSecond else { return "–" }
        return perSecond >= 100 ? String(format: "%.0f", perSecond) : String(format: "%.1f", perSecond)
    }

    static func cost(_ usd: Double) -> String {
        usd >= 1 ? String(format: "$%.2f", usd) : String(format: "$%.3f", usd)
    }

    /// "now", "42s", "12m", "3h", "2d"
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<10: return "now"
        case ..<60: return "\(seconds)s"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        return formatter
    }()

    static func resetTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = date.timeIntervalSinceNow < 20 * 3_600 ? timeFormatter : dayTimeFormatter
        return "resets \(formatter.string(from: date))"
    }
}
