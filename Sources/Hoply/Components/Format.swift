import AgentKit
import Foundation

enum Format {
    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fk", Double(count) / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(count) / 1_000_000)
        default: return String(format: "%.2fB", Double(count) / 1_000_000_000)
        }
    }

    static func rate(_ perSecond: Double?) -> String {
        guard let perSecond else { return "–" }
        return perSecond >= 100 ? String(format: "%.0f", perSecond) : String(format: "%.1f", perSecond)
    }

    static func cost(_ usd: Double) -> String {
        switch usd {
        case ..<0.000_5: return "$0"
        case ..<0.01: return "<$0.01"
        case ..<1_000: return String(format: "$%.2f", usd)
        default: return "$" + count(Int(usd.rounded()))
        }
    }

    /// Grouped like the rest of the app's figures ("1,234"), whatever the system locale, so it never reads
    /// as a decimal next to "$7.59" or "3.1M".
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// API-equivalent dollars from the ledger. A call with no known price must never read as $0.
    static func spend(_ totals: LedgerTotals) -> String {
        guard totals.hasUnpriced else { return cost(totals.apiEquivUSD) }
        return totals.apiEquivUSD > 0 ? cost(totals.apiEquivUSD) + "+" : "unpriced"
    }

    /// Copilot's own units, as secondary text next to a total: "182.7 premium req · 2,859 AIU". nil when the
    /// total has no Copilot usage.
    static func copilot(_ totals: LedgerTotals, compact: Bool = false) -> String? {
        guard totals.aiu > 0 || totals.premiumRequests > 0 else { return nil }
        return "\(premiumRequests(totals.premiumRequests)) \(compact ? "req" : "premium req") · \(aiu(totals.aiu)) AIU"
    }

    static func premiumRequests(_ value: Double) -> String {
        if value >= 1_000 { return count(Int(value.rounded())) }
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    static func aiu(_ value: Double) -> String {
        value >= 10 ? count(Int(value.rounded())) : String(format: "%.1f", value)
    }

    static func path(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func model(_ id: String) -> String {
        ModelName.display(id)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
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

    static func duration(from start: Date, to end: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / (24 * 60))d \(minutes / 60 % 24)h"
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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d jmm")
        return formatter
    }()

    static func resetTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = date.timeIntervalSinceNow < 20 * 3_600 ? timeFormatter : dayTimeFormatter
        return "Resets \(formatter.string(from: date))"
    }

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    /// Time only for today, otherwise the date.
    static func shortWhen(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? timeFormatter.string(from: date)
                                                        : shortDayFormatter.string(from: date)
    }

    /// "just now", "12m ago", "3h ago", then the date.
    static func lastActive(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 86_400 { return "\(age(since: date, now: now)) ago" }
        return shortWhen(date, now: now)
    }

    /// Time only for today, otherwise date and time.
    static func when(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? timeFormatter.string(from: date)
                                                        : dateTimeFormatter.string(from: date)
    }
}
