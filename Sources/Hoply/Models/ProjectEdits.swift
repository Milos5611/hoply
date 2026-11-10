import AgentKit
import AgentSystem
import Foundation
import Observation

@MainActor
@Observable
final class ProjectEdits {
    struct Usage: Equatable {
        var sessions: Int
        var totals: LedgerTotals
        var firstActive: Date?
    }

    struct Confirmation: Equatable {
        enum Action: Equatable {
            case merge(sources: [ProjectRef], target: ProjectRef, suggestion: MergeSuggestion?)
            case unmerge(MergedProject)
            case removeFolder(PathAssignment)
        }

        var action: Action
        var sessions: Int?
    }

    static let suggestionInterval: TimeInterval = 60

    private(set) var projects: [ProjectRef] = []
    private(set) var merged: [MergedProject] = []
    private(set) var folders: [PathAssignment] = []
    private(set) var sessions: [SessionAssignment] = []
    private(set) var suggestions: [MergeSuggestion] = []
    private(set) var usage: [Int64: Usage] = [:]
    private(set) var confirmation: Confirmation?
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var isWorking = false
    @ObservationIgnored var onEdited: (() -> Void)?

    @ObservationIgnored private let history: History
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var suggestionsLoadedAt = Date.distantPast

    init(history: History) {
        self.history = history
    }

    func merged(into project: ProjectRef) -> [MergedProject] {
        merged.filter { $0.into.id == project.id }
    }

    func folders(of project: ProjectRef) -> [PathAssignment] {
        folders.filter { $0.project.id == project.id }
    }

    func assignment(of key: SessionKey) -> SessionAssignment? {
        sessions.first { $0.key == key }
    }

    func targets(excluding project: ProjectRef?) -> [ProjectRef] {
        projects.filter { $0.id != project?.id }
    }

    // MARK: - Loading

    func reload(suggestions refresh: Bool = false) {
        guard let ledger = history.ledger else { return }
        generation += 1
        let generation = generation
        let withSuggestions = refresh || Date().timeIntervalSince(suggestionsLoadedAt) >= Self.suggestionInterval
        Task {
            do {
                let projects = try await ledger.projectList()
                let merged = try await ledger.mergedProjects()
                let folders = try await ledger.pathAssignments()
                let sessions = try await ledger.sessionAssignments()
                var suggestions = self.suggestions
                var usage = self.usage
                if withSuggestions {
                    suggestions = try await ledger.mergeSuggestions()
                    if !suggestions.isEmpty || confirmation != nil { usage = try await Self.usage(ledger) }
                }
                guard generation == self.generation, ledger.store === history.ledger?.store else { return }
                if withSuggestions { suggestionsLoadedAt = Date() }
                if projects != self.projects { self.projects = projects }
                if merged != self.merged { self.merged = merged }
                if folders != self.folders { self.folders = folders }
                if sessions != self.sessions { self.sessions = sessions }
                if suggestions != self.suggestions { self.suggestions = suggestions }
                if usage != self.usage { self.usage = usage }
            } catch {
                self.error = ProjectEditText.describe(error)
            }
        }
    }

    private static func usage(_ ledger: Ledger) async throws -> [Int64: Usage] {
        var usage: [Int64: Usage] = [:]
        for summary in try await ledger.reader.projects(in: HistoryRange.all.interval(), topModels: 0) {
            guard let project = summary.project else { continue }
            usage[project.id] = Usage(sessions: summary.sessionCount, totals: summary.totals,
                                      firstActive: summary.firstActive)
        }
        return usage
    }

    // MARK: - Confirmations

    func survivor(of suggestion: MergeSuggestion) -> ProjectRef? {
        suggestion.projects.enumerated().min { a, b in
            let (first, second) = (usage[a.element.id], usage[b.element.id])
            let (spendA, spendB) = (first?.totals.apiEquivUSD ?? 0, second?.totals.apiEquivUSD ?? 0)
            if spendA != spendB { return spendA > spendB }
            let (countA, countB) = (first?.sessions ?? 0, second?.sessions ?? 0)
            if countA != countB { return countA > countB }
            let (startA, startB) = (first?.firstActive ?? .distantFuture, second?.firstActive ?? .distantFuture)
            if startA != startB { return startA < startB }
            return a.offset < b.offset
        }?.element
    }

    func beginMerge(_ suggestion: MergeSuggestion, keeping survivor: ProjectRef? = nil) {
        guard let target = survivor ?? self.survivor(of: suggestion) else { return }
        ask(.merge(sources: suggestion.projects.filter { $0.id != target.id }, target: target, suggestion: suggestion))
    }

    func beginMerge(_ project: ProjectRef, into target: ProjectRef) {
        ask(.merge(sources: [project], target: target, suggestion: nil))
    }

    func beginUnmerge(_ merged: MergedProject) {
        ask(.unmerge(merged))
    }

    func beginRemoving(_ folder: PathAssignment) {
        ask(.removeFolder(folder))
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    private func ask(_ action: Confirmation.Action) {
        error = nil
        notice = nil
        confirmation = Confirmation(action: action, sessions: sessionCount(for: action))
        guard case .merge(let sources, _, _) = action, sources.contains(where: { usage[$0.id] == nil }),
              let ledger = history.ledger else { return }
        Task {
            guard let usage = try? await Self.usage(ledger), ledger.store === history.ledger?.store else { return }
            self.usage = usage
            if confirmation?.action == action { confirmation?.sessions = sessionCount(for: action) }
        }
    }

    private func sessionCount(for action: Confirmation.Action) -> Int? {
        guard case .merge(let sources, _, _) = action else { return nil }
        let counts = sources.map { usage[$0.id]?.sessions }
        return counts.contains(nil) ? nil : counts.compactMap { $0 }.reduce(0, +)
    }

    func confirm() {
        guard let confirmation else { return }
        switch confirmation.action {
        case .merge(let sources, let target, _):
            edit { ledger in
                for source in sources { try await ledger.mergeProject(source.id, into: target.id) }
            } then: { [history] in
                if let opened = history.openedProject?.project, sources.contains(where: { $0.id == opened.id }) {
                    history.openProject(target)
                }
            }
        case .unmerge(let merged):
            edit { try await $0.unmergeProject(merged.project.id) }
        case .removeFolder(let folder):
            edit { try await $0.unassign(path: folder.path) }
        }
    }

    // MARK: - Edits

    func addFolder(to project: ProjectRef) {
        guard history.ledger != nil, !isWorking else { return }
        Task {
            let message = "Sessions started in this folder and its subfolders count under \(project.title). "
                + "A repository inside it keeps its own project."
            guard let path = await WorkspaceActions.chooseFolder(message: message, startingAt: project.root) else { return }
            edit { try await $0.assign(path: path, toProject: project.id) }
        }
    }

    func assign(_ key: SessionKey, to project: ProjectRef) {
        edit { try await $0.assign(session: key, toProject: project.id) }
    }

    func unassign(_ key: SessionKey) {
        edit { try await $0.unassign(session: key) }
    }

    func dismiss(_ suggestion: MergeSuggestion) {
        guard let ledger = history.ledger else { return }
        if case .merge(_, _, let asked)? = confirmation?.action, asked?.id == suggestion.id { confirmation = nil }
        suggestions.removeAll { $0.id == suggestion.id }
        notice = nil
        Task {
            do {
                try await ledger.dismissSuggestion(suggestion)
            } catch {
                self.error = ProjectEditText.describe(error)
            }
            reload(suggestions: true)
        }
    }

    func restoreSuggestions() {
        guard let ledger = history.ledger else { return }
        let before = Set(suggestions.map(\.id))
        Task {
            do {
                try await ledger.restoreSuggestions()
                let restored = try await ledger.mergeSuggestions()
                guard ledger.store === history.ledger?.store else { return }
                let back = restored.count { !before.contains($0.id) }
                notice = back == 0 ? "No dismissed suggestions to bring back"
                    : back == 1 ? "1 suggestion is back" : "\(back) suggestions are back"
            } catch {
                self.error = ProjectEditText.describe(error)
            }
            reload(suggestions: true)
        }
    }

    func clearError() {
        error = nil
    }

    private func edit(_ work: @escaping (Ledger) async throws -> Void, then finish: (() -> Void)? = nil) {
        guard let ledger = history.ledger, !isWorking else { return }
        isWorking = true
        error = nil
        notice = nil
        Task {
            do {
                try await work(ledger)
                finish?()
            } catch {
                self.error = ProjectEditText.describe(error)
            }
            isWorking = false
            confirmation = nil
            history.ledgerEdited()
            onEdited?()
            reload(suggestions: true)
        }
    }
}

enum ProjectEditText {
    static func describe(_ error: any Error) -> String {
        switch error as? ProjectEditError {
        case .unknownProject: return "That project is no longer in the ledger. Nothing was changed."
        case .unknownSession: return "That session is no longer in the ledger. Nothing was changed."
        case .invalidPath(let path): return "\(Format.path(path)) can't be assigned to a project. Choose a folder below /."
        case .sameProject: return "Those are already the same project, so there is nothing to merge."
        case .notMerged: return "That project is not merged into another one any more."
        case nil: return "The change failed: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
        }
    }

    static func message(_ confirmation: ProjectEdits.Confirmation) -> String {
        switch confirmation.action {
        case .merge(let sources, let target, _):
            let moved: String
            switch confirmation.sessions {
            case 1?: moved = "Moves 1 session and its usage"
            case let count?: moved = "Moves \(Format.count(count)) sessions and their usage"
            case nil: moved = "Moves the sessions and usage of \(names(sources))"
            }
            return "\(moved) to \(target.title). You can unmerge later; sessions that changed folders may not return exactly."
        case .unmerge(let merged):
            return "Sessions started in \(Format.path(merged.project.root)) go back to \(merged.project.title). "
                + "This goes by each session's folder, so sessions that changed folders may stay in \(merged.into.title)."
        case .removeFolder(let folder):
            return "Sessions started in \(Format.path(folder.path)) go back to the project Hoply finds for that folder. "
                + "Sessions you assigned one by one stay where they are."
        }
    }

    static func confirmTitle(_ confirmation: ProjectEdits.Confirmation) -> String {
        switch confirmation.action {
        case .merge: return "Merge"
        case .unmerge: return "Unmerge"
        case .removeFolder: return "Remove"
        }
    }

    static func names(_ projects: [ProjectRef]) -> String {
        let names = projects.map(\.title)
        guard names.count > 2 else { return names.joined(separator: " and ") }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }
}

struct ProjectEditsPreview {
    var projects: [ProjectRef] = []
    var merged: [MergedProject] = []
    var folders: [PathAssignment] = []
    var sessions: [SessionAssignment] = []
    var suggestions: [MergeSuggestion] = []
    var usage: [Int64: ProjectEdits.Usage] = [:]
}

extension ProjectEdits {
    func show(_ preview: ProjectEditsPreview, error: String? = nil) {
        projects = preview.projects
        merged = preview.merged
        folders = preview.folders
        sessions = preview.sessions
        suggestions = preview.suggestions
        usage = preview.usage
        confirmation = nil
        self.error = error
        notice = nil
    }
}
