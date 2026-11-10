import AgentKit
import SwiftUI

extension CleanupKind {
    var title: String {
        switch self {
        case .worktree: return "Worktrees"
        case .buildCache: return "Build caches"
        case .transcript: return "Claude transcripts"
        case .orphanProcess: return "Orphan processes"
        }
    }

    var symbol: String {
        switch self {
        case .worktree: return "arrow.triangle.branch"
        case .buildCache: return "shippingbox"
        case .transcript: return "text.bubble"
        case .orphanProcess: return "bolt.horizontal"
        }
    }

    var tint: Color {
        switch self {
        case .worktree: return .indigo
        case .buildCache: return .blue
        case .transcript: return .orange
        case .orphanProcess: return .red
        }
    }

    var rule: String {
        switch self {
        case .worktree: return "Merged, clean and idle for a week"
        case .buildCache: return "Over 50 MB in projects idle for two weeks"
        case .transcript: return "Older than 90 days and fully in Hoply's history"
        case .orphanProcess: return "Left running by an agent session that has ended"
        }
    }

    var consequence: String {
        switch self {
        case .worktree: return "Worktree folders move to the Trash and git forgets them. Their branches stay."
        case .buildCache: return "Build caches are rebuilt the next time the project builds."
        case .transcript:
            return "Transcripts move to the Trash. Their usage stays in Hoply, but Claude Code can no longer resume those sessions."
        case .orphanProcess: return "Processes are asked to quit, then force quit after 5 seconds."
        }
    }

    var isProcess: Bool { self == .orphanProcess }
}

extension CleanupCandidate {
    var sizeLabel: String {
        bytes > 0 ? Format.bytes(bytes) : "–"
    }

    var revealPath: String? {
        path ?? orphan?.cwd
    }

    var facts: String {
        var parts: [String] = []
        if let orphan {
            parts.append("pid \(orphan.identity.pid)")
            parts.append("started by \(orphan.agent.displayName)")
            if let cwd = orphan.cwd { parts.append(Format.path(cwd)) }
            return parts.joined(separator: " · ")
        }
        if let branch { parts.append(branch) }
        if let project { parts.append(project.title) }
        if kind != .transcript, let path { parts.append(Format.path(path)) }
        if let lastActive {
            parts.append("\(kind == .transcript ? "last written" : "last active") \(Format.shortWhen(lastActive))")
        }
        return parts.joined(separator: " · ")
    }

    var keptBecause: String {
        keepReasons.map(\.explanation).joined(separator: " · ")
    }
}

extension CleanupReport.Outcome {
    var explanation: String? {
        switch self {
        case .trashed, .terminated: return nil
        case .killed: return "Force quit"
        case .skipped(let reasons): return reasons.map(\.explanation).joined(separator: " · ")
        case .failed(let message): return message
        }
    }
}

enum CleanupSummary {
    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    static func action(for candidates: [CleanupCandidate]) -> String {
        let processes = candidates.filter(\.kind.isProcess).count
        if processes == candidates.count { return processes == 1 ? "Terminate" : "Terminate \(processes)" }
        return processes == 0 ? "Move to Trash" : "Clean up"
    }

    static func headline(_ report: CleanupReport) -> String {
        let trashed = report.removed.filter { !$0.candidate.kind.isProcess }.count
        let stopped = report.removed.count - trashed
        var parts: [String] = []
        if trashed > 0 { parts.append("Moved \(items(trashed)) to the Trash · \(Format.bytes(report.bytesFreed)) freed") }
        if stopped > 0 { parts.append(stopped == 1 ? "1 process stopped" : "\(stopped) processes stopped") }
        return parts.isEmpty ? "Nothing was removed" : parts.joined(separator: " · ")
    }
}
