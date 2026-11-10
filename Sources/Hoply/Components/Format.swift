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

    static func tokens(_ count: Double) -> String {
        tokens(whole(count))
    }

    /// Rounded to an Int. Model-server readings can be NaN or infinite, which `Int(_:)` traps on.
    static func whole(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), -1e15), 1e15))
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

    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// API-equivalent dollars from the ledger. A call with no known price must never read as $0.
    static func spend(_ totals: LedgerTotals) -> String {
        guard totals.hasUnpriced else { return cost(totals.apiEquivUSD) }
        return totals.apiEquivUSD > 0 ? cost(totals.apiEquivUSD) + "+" : "unpriced"
    }

    static func copilot(_ totals: LedgerTotals, compact: Bool = false) -> String? {
        guard totals.aiu > 0 || totals.premiumRequests > 0 else { return nil }
        return "\(premiumRequests(totals.premiumRequests)) \(compact ? "req" : "premium req") · \(aiu(totals.aiu)) AIU"
    }

    static func money(_ money: ClaudeLimits.Spend.Money) -> String {
        money.amount.formatted(.currency(code: money.currency)
            .precision(.fractionLength(min(money.exponent, 4)))
            .locale(Locale(identifier: "en_US")))
    }

    static func engine(_ engine: String) -> String {
        engine == "vllm" ? "vLLM" : engine
    }

    static func servedModel(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    static func compact(_ value: Double) -> String {
        switch value {
        case ..<100: return String(format: "%.1f", value)
        case ..<10_000: return count(Int(value.rounded()))
        default: return String(format: "%.1fk", value / 1_000)
        }
    }

    static func premiumRequests(_ value: Double) -> String {
        if value >= 1_000 { return count(Int(value.rounded())) }
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    static func aiu(_ value: Double) -> String {
        value >= 10 ? count(Int(value.rounded())) : String(format: "%.1f", value)
    }

    static func diffSummary(_ diff: GitDiffStat, path: String? = nil) -> String {
        var parts: [String] = []
        if diff.filesChanged > 0 {
            parts.append("\(diff.filesChanged) \(diff.filesChanged == 1 ? "file" : "files") changed, +\(diff.added) −\(diff.removed)")
        }
        if diff.untracked > 0 {
            parts.append("\(diff.untracked) untracked \(diff.untracked == 1 ? "file" : "files")")
        }
        let place = path.map { " in \(Self.path($0))" } ?? ""
        return "Uncommitted\(place): " + parts.joined(separator: ", ")
    }

    static func contextSummary(_ context: ContextWindow) -> String {
        "Context window: \(tokens(context.used)) of \(tokens(context.limit)) tokens used, \(tokens(context.remaining)) left"
    }

    static func usdPerMillion(_ usd: Double) -> String {
        usd < 0.01 ? "<$0.01" : String(format: "$%.2f", usd)
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
        "\(whole(min(max(fraction, 0), 1) * 100))%"
    }

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

    static func clock(_ date: Date, now: Date = Date()) -> String {
        let formatter = abs(date.timeIntervalSince(now)) < 20 * 3_600 ? timeFormatter : dayTimeFormatter
        return formatter.string(from: date)
    }

    static func timeOfDay(minutes: Int) -> String {
        timeFormatter.string(from: date(minutesAfterMidnight: minutes))
    }

    /// Today at that time; through the calendar, so a DST change doesn't shift it by an hour.
    static func date(minutesAfterMidnight minutes: Int, on day: Date = Date()) -> Date {
        let minutes = ((minutes % 1_440) + 1_440) % 1_440
        return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }

    static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded(.up)), 1)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        return hours % 24 == 0 ? "\(hours / 24) d" : "\(hours / 24) d \(hours % 24) h"
    }

    private static let utcDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        formatter.timeZone = .gmt
        return formatter
    }()

    private static let utcMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        formatter.timeZone = .gmt
        return formatter
    }()

    /// GitHub's Copilot counters reset at 00:00 UTC, so their dates read in UTC.
    static func utcDay(_ date: Date) -> String {
        utcDayFormatter.string(from: date)
    }

    static func utcMonth(_ date: Date) -> String {
        utcMonthFormatter.string(from: date)
    }

    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    static func shortWhen(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? timeFormatter.string(from: date)
                                                        : shortDayFormatter.string(from: date)
    }

    static func lastActive(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 86_400 { return "\(age(since: date, now: now)) ago" }
        return shortWhen(date, now: now)
    }

    static func when(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? timeFormatter.string(from: date)
                                                        : dateTimeFormatter.string(from: date)
    }
}
