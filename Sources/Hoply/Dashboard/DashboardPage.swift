import AgentSystem
import Foundation

enum DashboardPage: String, CaseIterable, Identifiable, Hashable {
    case overview
    case projects
    case sessions
    case spending
    case localModel = "local-model"
    case limits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .projects: return "Projects"
        case .sessions: return "Sessions"
        case .spending: return "Spending"
        case .localModel: return "Local model"
        case .limits: return "Limits"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .projects: return "folder"
        case .sessions: return "list.bullet.rectangle"
        case .spending: return "chart.bar.xaxis"
        case .localModel: return "cpu"
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

enum LocalModelRange: String, CaseIterable, Identifiable, Hashable {
    case day
    case week
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "24 hours"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }

    var resolution: Int {
        switch self {
        case .day: return 300
        case .week: return 1_800
        case .month: return 3_600
        }
    }

    var resolutionLabel: String {
        switch self {
        case .day: return "5 minutes"
        case .week: return "30 minutes"
        case .month: return "hour"
        }
    }

    var dailyDays: Int { self == .month ? 30 : 7 }

    func interval(now: Date = Date()) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-duration), end: now)
    }
}
