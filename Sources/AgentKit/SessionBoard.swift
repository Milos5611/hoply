import Foundation

public struct StateChange: Sendable, Equatable {
    public let session: AgentSession
    public let from: SessionState?
    public let to: SessionState
    public let previousDuration: TimeInterval
}

public struct SessionBoard: Sendable {
    public private(set) var sessions: [SessionKey: AgentSession] = [:]

    public var idleAfter: TimeInterval = 45
    public var dropAfter: TimeInterval = 4 * 3600
    public var keepEndedFor: TimeInterval = 600

    public init() {}

    public var ordered: [AgentSession] {
        sessions.values.sorted { a, b in
            let (left, right) = (SessionStatus(a).priority, SessionStatus(b).priority)
            if left != right { return left < right }
            return a.lastEventAt > b.lastEventAt
        }
    }

    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> StateChange? {
        let existing = sessions[event.key]
        var session = existing ?? AgentSession(key: event.key, at: event.time)

        if existing?.state == .ended, event.kind == .sessionStarted {
            session = AgentSession(key: event.key, at: event.time)
        }

        // A hook that fires inside a subagent reports the subagent's cwd, which may be its own worktree.
        let subagent = event.fromHook ? event.agentID.flatMap { $0.isEmpty ? nil : $0 } : nil
        if event.time > session.lastEventAt { session.lastEventAt = event.time }
        if subagent == nil, let cwd = event.cwd, !cwd.isEmpty { session.cwd = cwd }
        if subagent == nil, let model = event.model, !model.isEmpty { session.model = model }
        if event.fromHook { session.hasLiveState = true }
        if event.fromHook, let pid = event.agentPID, pid != session.reportedPID {
            session.reportedPID = pid
            session.pidReportedAt = event.time
        }
        if let subagent, session.state != .ended {
            Self.touch(&session, subagent: subagent, type: event.agentType, at: event.time)
        }

        var next: SessionState?
        var keepsQuestion = false
        var asksQuestion = false
        switch event.kind {
        case .sessionStarted:
            next = existing == nil ? .idle : nil
        case .promptSubmitted(let prompt):
            next = .working
            if session.title == nil, let title = Self.title(from: prompt) { session.title = title }
            session.lastMessage = nil
            session.turnEnded = false
            session.failure = nil
        case .toolStarted(let tool), .toolFinished(let tool):
            if subagent == nil {
                next = .working
                session.turnEnded = false
                session.failure = nil
                if let tool, !tool.isEmpty { session.lastTool = tool }
            } else if !session.turnEnded {
                next = .working
            } else if session.state == .needsPermission {
                // A background subagent got its answer; the main agent's turn is still over.
                next = .yourTurn
            }
        case .needsPermission(let message):
            next = .needsPermission
            session.lastMessage = Self.short(message)
        case .waitingForInput(let message):
            next = .yourTurn
            keepsQuestion = true
            if let message = Self.short(message) { session.lastMessage = message }
        case .questionAsked(let message):
            next = .yourTurn
            asksQuestion = true
            if let message = Self.short(message) { session.lastMessage = message }
        case .turnFinished(let message):
            next = .yourTurn
            session.turnEnded = true
            session.failure = nil
            if let message = Self.short(message) { session.lastMessage = message }
        case .turnFailed(let error, let message):
            next = .yourTurn
            session.turnEnded = true
            session.failure = error.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            if let message = Self.short(message ?? error) { session.lastMessage = message }
        case .subagentStarted(let id, let type):
            if session.state != .ended { Self.touch(&session, subagent: id, type: type, at: event.time, restart: true) }
        case .subagentStopped(let id, let type):
            Self.stop(&session, subagent: id, type: type, at: event.time)
        case .sessionEnded:
            next = .ended
            session.turnEnded = true
            for index in session.subagents.indices where session.subagents[index].isWorking {
                session.subagents[index].endedAt = event.time
            }
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
        if session.state == .ended && event.kind != .sessionStarted && existing != nil { next = nil }
        if next != nil { session.awaitsInput = asksQuestion || (keepsQuestion && session.awaitsInput) }

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

    private static func touch(_ session: inout AgentSession, subagent id: String, type: String?, at time: Date,
                              restart: Bool = false) {
        let type = type.flatMap { $0.isEmpty ? nil : $0 }
        if let index = session.subagents.firstIndex(where: { $0.id == id }) {
            session.subagents[index].lastEventAt = max(session.subagents[index].lastEventAt, time)
            if let type { session.subagents[index].type = type }
            if restart { session.subagents[index].endedAt = nil }
            return
        }
        session.subagents.append(LiveSubagent(id: id, type: type, startedAt: time))
        if session.subagents.count > AgentSession.maxSubagents {
            let oldest = session.subagents.firstIndex { !$0.isWorking } ?? 0
            session.subagents.remove(at: oldest)
        }
    }

    // `SubagentStop` also fires for Claude Code's internal agents (no type, never started): not subagents.
    private static func stop(_ session: inout AgentSession, subagent id: String, type: String?, at time: Date) {
        if session.subagents.contains(where: { $0.id == id }) {
            touch(&session, subagent: id, type: type, at: time)
        } else if let type, !type.isEmpty, session.state != .ended {
            touch(&session, subagent: id, type: type, at: time)
        }
        if let index = session.subagents.firstIndex(where: { $0.id == id }), session.subagents[index].isWorking {
            session.subagents[index].endedAt = time
        }
    }

    public struct Sweep: Sendable, Equatable {
        public var changes: [StateChange]
        public var dropped: [AgentSession]

        public init(changes: [StateChange] = [], dropped: [AgentSession] = []) {
            self.changes = changes
            self.dropped = dropped
        }
    }

    @discardableResult
    public mutating func tick(now: Date) -> [StateChange] {
        sweep(now: now).changes
    }

    public mutating func sweep(now: Date) -> Sweep {
        var changes: [StateChange] = []
        var dropped: [AgentSession] = []
        for (key, session) in sessions {
            let silence = now.timeIntervalSince(session.lastEventAt)
            let expired = session.state == .ended && now.timeIntervalSince(session.stateSince) > keepEndedFor
            if silence > dropAfter || expired {
                sessions[key] = nil
                dropped.append(session)
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
        return Sweep(changes: changes, dropped: dropped.sorted { $0.lastEventAt < $1.lastEventAt })
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
        // Harness-injected turns (`<agent-message …>`, `<task-notification>`, `<command-name>`) also arrive
        // as prompts; skipping them lets the next typed prompt name the session.
        guard !firstLine.isEmpty, !firstLine.hasPrefix("<") else { return nil }
        return firstLine.count > 80 ? String(firstLine.prefix(79)) + "…" : firstLine
    }

    static func short(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 140 ? String(oneLine.prefix(139)) + "…" : oneLine
    }
}
