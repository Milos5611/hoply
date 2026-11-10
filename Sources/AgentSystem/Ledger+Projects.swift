import AgentKit
import Foundation

extension Ledger {
    public func projectList() async throws -> [ProjectRef] {
        try await reader.projectList()
    }

    public func assign(path: String, toProject projectID: Int64) async throws {
        await ingest.noteChanged(try await store.assign(path: path, toProject: projectID))
    }

    public func unassign(path: String) async throws {
        await ingest.noteChanged(try await store.unassign(path: path))
    }

    public func pathAssignments() async throws -> [PathAssignment] {
        try await reader.pathAssignments()
    }

    public func mergeProject(_ projectID: Int64, into targetID: Int64) async throws {
        await ingest.noteChanged(try await store.mergeProject(projectID, into: targetID))
    }

    public func unmergeProject(_ projectID: Int64) async throws {
        await ingest.noteChanged(try await store.unmergeProject(projectID))
    }

    public func mergedProjects() async throws -> [MergedProject] {
        try await reader.mergedProjects()
    }

    public func assign(session key: SessionKey, toProject projectID: Int64) async throws {
        await ingest.noteChanged(try await store.assign(session: key, toProject: projectID))
    }

    public func unassign(session key: SessionKey) async throws {
        await ingest.noteChanged(try await store.unassign(session: key))
    }

    public func sessionAssignments() async throws -> [SessionAssignment] {
        try await reader.sessionAssignments()
    }

    public func mergeSuggestions() async throws -> [MergeSuggestion] {
        try await store.mergeSuggestions()
    }

    public func dismissSuggestion(_ suggestion: MergeSuggestion) async throws {
        try await store.dismissSuggestion(suggestion.id)
    }

    public func restoreSuggestions() async throws {
        try await store.restoreSuggestions()
    }

    public func recordStateChanges(_ changes: [StateChange]) async throws {
        try await store.recordStateChanges(changes)
    }

    public func trackStateSpans(of sessions: [AgentSession]) async throws {
        try await store.trackStateSpans(of: sessions)
    }

    public func closeStateSpans(for keys: [SessionKey], at time: Date = Date()) async throws {
        try await store.closeStateSpans(for: keys, at: time)
    }

    public func closeAllStateSpans(at time: Date = Date()) async throws {
        try await store.closeAllStateSpans(at: time)
    }

    public func stateSpans(of key: SessionKey) async throws -> [StateSpan] {
        try await reader.stateSpans(of: key)
    }
}
