import AgentSystem
import Foundation

enum DashboardPage: String, CaseIterable, Identifiable, Hashable {
    case overview
    case projects
    case sessions
    case spending
    case limits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .projects: return "Projects"
        case .sessions: return "Sessions"
        case .spending: return "Spending"
        case .limits: return "Limits"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .projects: return "folder"
        case .sessions: return "list.bullet.rectangle"
        case .spending: return "chart.bar.xaxis"
        case .limits: return "gauge.with.dots.needle.67percent"
        }
    }
}

enum HistoryRange: String, CaseIterable, Identifiable, Hashable {
    case today
    case week
    case month
    case quarter
    case all

    static let spendingRanges: [HistoryRange] = [.week, .month, .quarter]
    static let projectRanges: [HistoryRange] = [.week, .month, .quarter, .all]

    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .all: return nil
        }
    }

    var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        case .quarter: return "90 days"
        case .all: return "All time"
        }
    }

    var shortLabel: String {
        self == .all ? "All" : label
    }

    func interval(now: Date = Date()) -> DateInterval {
        let today = StoreReader.days(1, endingAt: now)
        guard let days else { return DateInterval(start: Date(timeIntervalSince1970: 0), end: today.end) }
        return StoreReader.days(days, endingAt: now)
    }
}
