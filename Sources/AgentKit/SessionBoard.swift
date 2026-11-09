import Foundation

/// A session moved from one state to another.
public struct StateChange: Sendable, Equatable {
    public let session: AgentSession
    public let from: SessionState?
    public let to: SessionState
    /// How long the session had been in `from` before this change.
    public let previousDuration: TimeInterval
}

/// Holds every known session and applies events to it. Pure value type, so it is easy to test
/// and safe to own from the main actor.
public struct SessionBoard: Sendable {
    public private(set) var sessions: [SessionKey: AgentSession] = [:]

    /// Telemetry-only sessions (no hooks) fall back to idle after this much silence.
    public var idleAfter: TimeInterval = 45
    /// Sessions with no events at all for this long are dropped.
    public var dropAfter: TimeInterval = 4 * 3600
    /// Ended sessions stay visible this long.
    public var keepEndedFor: TimeInterval = 600

    public init() {}

    /// Sessions in panel order: what needs you first, then what's working, newest activity first.
    public var ordered: [AgentSession] {
        sessions.values.sorted { a, b in
            if a.state.priority != b.state.priority { return a.state.priority < b.state.priority }
            return a.lastEventAt > b.lastEventAt
        }
    }

    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> StateChange? {
        let existing = sessions[event.key]
        var session = existing ?? AgentSession(key: event.key, at: event.time)

        // A new session id arriving for an ended session means a fresh start.
        if existing?.state == .ended, event.kind == .sessionStarted {
            session = AgentSession(key: event.key, at: event.time)
        }

        if event.time > session.lastEventAt { session.lastEventAt = event.time }
        if let cwd = event.cwd, !cwd.isEmpty { session.cwd = cwd }
        if let model = event.model, !model.isEmpty { session.model = model }
        if event.fromHook { session.hasLiveState = true }

        var next: SessionState?
        switch event.kind {
        case .sessionStarted:
            next = existing == nil ? .idle : nil
        case .promptSubmitted(let prompt):
            next = .working
            if session.title == nil, let title = Self.title(from: prompt) { session.title = title }
            session.lastMessage = nil
        case .toolStarted(let tool):
            next = .working
            if let tool, !tool.isEmpty { session.lastTool = tool }
        case .toolFinished(let tool):
            next = .working
            if let tool, !tool.isEmpty { session.lastTool = tool }
        case .needsPermission(let message):
            next = .needsPermission
            session.lastMessage = Self.short(message)
        case .waitingForInput(let message):
            next = .yourTurn
            if let message = Self.short(message) { session.lastMessage = message }
        case .turnFinished(let message):
            next = .yourTurn
            if let message = Self.short(message) { session.lastMessage = message }
        case .sessionEnded:
            next = .ended
        case .error(let message):
            session.lastMessage = Self.short(message)
        case .usage(let usage):
            session.inputTokens += usage.inputTokens
            session.outputTokens += usage.outputTokens
            session.cacheTokens += usage.cacheTokens
            session.costUSD += usage.costUSD
            next = .working
        case .activity:
            next = .working
        }

        // Hooks own the state once they have spoken; delayed telemetry must not undo it.
        if !event.fromHook && session.hasLiveState { next = nil }
        // Nothing revives an ended session except a new start.
        if session.state == .ended && event.kind != .sessionStarted && existing != nil { next = nil }

        var change: StateChange?
        if let next, next != session.state || existing == nil {
            let from = existing?.state
            let previousDuration = existing.map { event.time.timeIntervalSince($0.stateSince) } ?? 0
            session.state = next
            session.stateSince = event.time
            change = StateChange(session: session, from: from, to: next, previousDuration: previousDuration)
        } else if existing == nil {
            change = StateChange(session: session, from: nil, to: session.state, previousDuration: 0)
        }

        sessions[event.key] = session
        return change
    }

    /// Time-based housekeeping. Call every few seconds.
    @discardableResult
    public mutating func tick(now: Date) -> [StateChange] {
        var changes: [StateChange] = []
        for (key, session) in sessions {
            let silence = now.timeIntervalSince(session.lastEventAt)
            if silence > dropAfter {
                sessions[key] = nil
                continue
            }
            if session.state == .ended, now.timeIntervalSince(session.stateSince) > keepEndedFor {
                sessions[key] = nil
                continue
            }
            if !session.hasLiveState, session.state == .working, silence > idleAfter {
                var updated = session
                updated.state = .idle
                updated.stateSince = now
                sessions[key] = updated
                changes.append(StateChange(session: updated, from: .working, to: .idle,
                                           previousDuration: now.timeIntervalSince(session.stateSince)))
            }
        }
        return changes
    }

    public mutating func dismiss(_ key: SessionKey) {
        sessions[key] = nil
    }

    static func title(from prompt: String?) -> String? {
        guard let prompt else { return nil }
        let firstLine = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty, firstLine != "<REDACTED>" else { return nil }
        return firstLine.count > 80 ? String(firstLine.prefix(79)) + "…" : firstLine
    }

    static func short(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 140 ? String(oneLine.prefix(139)) + "…" : oneLine
    }
}
