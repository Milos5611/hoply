import Foundation

public enum CleanupKeepReason: Sendable, Equatable, Hashable {
    case mainWorktree
    case locked
    case gitStateUnknown
    case uncommittedChanges
    case notMerged(branch: String?, into: String)
    case untrackedWorktree
    case sessionRunning
    case devServerRunning
    case recentlyActive(idleDays: Int, requiredDays: Int)
    case activityUnknown
    case tooSmall(bytes: Int64, minimumBytes: Int64)
    case notIgnored
    case recentlyWritten(ageDays: Int, requiredDays: Int)
    case notFullyIngested
    case missing
    case outsideKnownFolders
    case historyOff
    case process(DevServerStop.Refusal)

    public var explanation: String {
        switch self {
        case .mainWorktree: return "Main worktree"
        case .locked: return "Locked"
        case .gitStateUnknown: return "Could not read git state"
        case .uncommittedChanges: return "Has uncommitted changes"
        case .notMerged(let branch?, let target): return "Branch \(branch) is not merged into \(target)"
        case .notMerged(nil, let target): return "Detached HEAD is not part of \(target)"
        case .untrackedWorktree: return "Git no longer tracks this worktree; remove it yourself"
        case .sessionRunning: return "A session is running here"
        case .devServerRunning: return "A dev server is running here"
        case .recentlyActive(let idle, let required):
            return "Active \(Self.daysAgo(idle)); needs \(required) idle days"
        case .activityUnknown: return "No recorded activity to judge idle time"
        case .tooSmall(let bytes, _): return "Only \(Self.megabytes(bytes))"
        case .notIgnored: return "Not ignored by git"
        case .recentlyWritten(let age, let required):
            return "Last written \(Self.daysAgo(age)); needs \(required) days"
        case .notFullyIngested: return "Not fully ingested yet"
        case .missing: return "No longer exists"
        case .outsideKnownFolders: return "Outside the folders Hoply cleans"
        case .historyOff: return "History is off"
        case .process(let refusal): return Self.explanation(of: refusal)
        }
    }

    private static func daysAgo(_ days: Int) -> String {
        switch days {
        case ..<1: return "today"
        case 1: return "1 day ago"
        default: return "\(days) days ago"
        }
    }

    private static func megabytes(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        return megabytes < 1 && bytes > 0 ? "under 1 MB" : "\(Int(megabytes.rounded())) MB"
    }

    private static func explanation(of refusal: DevServerStop.Refusal) -> String {
        switch refusal {
        case .processGone: return "No longer running"
        case .identityChanged: return "Another process now has this process id"
        case .notOurUser: return "Belongs to another user"
        case .includesHoply: return "Stopping it would stop Hoply"
        case .includesAgent: return "An agent session runs in its process tree"
        case .noProcessGroup, .leaderGone, .leaderOutsideProject: return refusal.reason
        }
    }
}
