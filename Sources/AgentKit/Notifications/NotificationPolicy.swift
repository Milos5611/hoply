import Foundation

public enum NotificationKind: String, Sendable, Hashable {
    case permission
    case yourTurn = "your-turn"
    case limit
    case localModelOffline = "local-model-offline"
}

public enum NotificationCause: String, Sendable, Hashable, CaseIterable {
    case permission
    case input
    case yourTurn = "your-turn"
    case limit
    case limitReset = "limit-reset"
    case localModelOffline = "local-model-offline"

    public var kind: NotificationKind {
        switch self {
        case .permission, .input: return .permission
        case .yourTurn: return .yourTurn
        case .limit, .limitReset: return .limit
        case .localModelOffline: return .localModelOffline
        }
    }

    public init(_ kind: NotificationKind) {
        switch kind {
        case .permission: self = .permission
        case .yourTurn: self = .yourTurn
        case .limit: self = .limit
        case .localModelOffline: self = .localModelOffline
        }
    }
}

public enum NotificationInterruption: String, Sendable {
    case active
    case passive
}

public struct NotificationRequest: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: NotificationKind
    public var cause: NotificationCause
    public var interruption: NotificationInterruption
    public var title: String
    public var body: String
    public var threadID: String
    public var session: SessionKey?

    public init(id: String, kind: NotificationKind, interruption: NotificationInterruption, title: String,
                body: String, threadID: String, session: SessionKey? = nil, cause: NotificationCause? = nil) {
        self.id = id
        self.kind = kind
        self.cause = cause ?? NotificationCause(kind)
        self.interruption = interruption
        self.title = title
        self.body = body
        self.threadID = threadID
        self.session = session
    }

    public var playsSound: Bool { interruption == .active }
}

public struct NotificationActions: Sendable, Equatable {
    public var post: [NotificationRequest]
    public var withdraw: [String]

    public init(post: [NotificationRequest] = [], withdraw: [String] = []) {
        self.post = post
        self.withdraw = withdraw
    }

    public var isEmpty: Bool { post.isEmpty && withdraw.isEmpty }
}

public struct QuietHours: Sendable, Equatable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = Self.normalized(start)
        self.end = Self.normalized(end)
    }

    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if start == end { return false }
        return start < end ? (start..<end).contains(minute) : minute >= start || minute < end
    }

    private static func normalized(_ minutes: Int) -> Int {
        ((minutes % 1440) + 1440) % 1440
    }
}

public struct NotificationPreferences: Sendable, Equatable {
    public var enabled: Bool
    public var quietHours: QuietHours?
    public var mutedProjectRoots: Set<String>
    public var limitAlerts: Bool
    public var localModelAlerts: Bool

    public init(enabled: Bool = true, quietHours: QuietHours? = nil, mutedProjectRoots: Set<String> = [],
                limitAlerts: Bool = true, localModelAlerts: Bool = true) {
        self.enabled = enabled
        self.quietHours = quietHours
        self.mutedProjectRoots = mutedProjectRoots
        self.limitAlerts = limitAlerts
        self.localModelAlerts = localModelAlerts
    }

    public init(settings: AppSettings) {
        self.init(enabled: settings.notificationsEnabled,
                  quietHours: settings.quietHoursEnabled
                      ? QuietHours(start: settings.quietHoursStart, end: settings.quietHoursEnd) : nil,
                  mutedProjectRoots: Set(settings.mutedProjectRoots),
                  limitAlerts: settings.limitAlertsEnabled, localModelAlerts: settings.localModelAlertsEnabled)
    }
}

public struct NotificationPolicy: Sendable {
    public var preferences: NotificationPreferences
    public var calendar: Calendar

    public static let cooldown: TimeInterval = 120
    public static let minimumWork: TimeInterval = 30
    public static let limitThresholds: [Double] = [80, 95]
    public static let offlineAlertAfter: TimeInterval = 120
    public static let offlineCheckGap: TimeInterval = 90
    public static let localModelOfflineID = "local-model:offline"
    public static let limitsThreadID = "limits"
    public static let localModelThreadID = "local-model"

    private struct Cooldown: Hashable {
        var session: SessionKey
        var cause: NotificationCause
    }

    private struct LimitedWatch {
        var kind: LimitKind
        var resetsAt: Date
        var sessions: Set<SessionKey>
    }

    private struct LocalModelWatch {
        var server: String?
        var seenOnline = false
        var offlineSince: Date?
        var lastCheck: Date?
        var alerted = false
    }

    private var lastPosted: [Cooldown: Date] = [:]
    private var lastLimitSamples: [LimitKind: LimitSample] = [:]
    private var postedLimitAlerts: [String: Date] = [:]
    private var localModel = LocalModelWatch()
    private var limitedWatch: LimitedWatch?

    public init(preferences: NotificationPreferences = NotificationPreferences(), calendar: Calendar = .current) {
        self.preferences = preferences
        self.calendar = calendar
    }

    public static func notificationID(for key: SessionKey) -> String {
        "session:\(key.source.rawValue):\(key.id)"
    }

    public func isQuiet(at date: Date) -> Bool {
        preferences.quietHours?.contains(date, calendar: calendar) ?? false
    }

    public func isMuted(_ session: AgentSession, project: ProjectRef?) -> Bool {
        if let root = Self.nonEmpty(project?.root).map(Self.normalized) {
            return preferences.mutedProjectRoots.contains { Self.normalized($0) == root }
        }
        // Unresolved (e.g. right after launch): the cwd may be a worktree or subfolder of a muted repo.
        guard let cwd = Self.nonEmpty(session.cwd).map(Self.normalized) else { return false }
        return preferences.mutedProjectRoots.contains { muted in
            let root = Self.normalized(muted)
            guard !root.isEmpty else { return false }
            return cwd == root || cwd.hasPrefix(root == "/" ? root : root + "/")
        }
    }

    // MARK: - Sessions

    public mutating func sessionChanged(_ change: StateChange, project: ProjectRef? = nil,
                                        now: Date = Date()) -> NotificationActions {
        let session = change.session
        let id = Self.notificationID(for: session.key)
        var actions = NotificationActions()
        if let from = change.from, from.needsAttention, !change.to.needsAttention {
            actions.withdraw.append(id)
        }
        lastPosted = lastPosted.filter { now.timeIntervalSince($0.value) < Self.cooldown }

        guard change.from != change.to, let cause = Self.cause(of: change) else { return actions }
        let cooldown = Cooldown(session: session.key, cause: cause)
        guard preferences.enabled, !isQuiet(at: now), !isMuted(session, project: project),
              lastPosted[cooldown] == nil else { return actions }
        lastPosted[cooldown] = now

        let source = session.key.source.displayName
        let projectTitle = project?.title ?? session.project
        let title: String
        switch cause {
        case .permission: title = "\(source) needs permission"
        case .input: title = "\(source) has a question"
        default: title = "\(source) is waiting for you"
        }
        actions.post.append(NotificationRequest(
            id: id, kind: cause.kind, interruption: cause == .yourTurn ? .passive : .active, title: title,
            body: [session.title, projectTitle].compactMap { Self.nonEmpty($0) }.joined(separator: " · "),
            threadID: Self.place(of: session, project: project) ?? session.key.source.rawValue,
            session: session.key, cause: cause))
        return actions
    }

    public mutating func sessionDismissed(_ key: SessionKey) -> NotificationActions {
        NotificationActions(withdraw: [Self.notificationID(for: key)])
    }

    private static func cause(of change: StateChange) -> NotificationCause? {
        switch change.to {
        case .needsPermission:
            return .permission
        case .yourTurn where change.session.awaitsInput:
            return .input
        case .yourTurn where change.from == .working && change.previousDuration >= minimumWork:
            return .yourTurn
        default:
            return nil
        }
    }

    // MARK: - Claude limits

    public mutating func limitsUpdated(_ samples: [LimitSample], previous stored: [LimitKind: LimitSample]?,
                                       now: Date = Date()) -> NotificationActions {
        postedLimitAlerts = postedLimitAlerts.filter { now.timeIntervalSince($0.value) < 86_400 }
        var actions = NotificationActions()
        for sample in samples {
            let previous = [stored?[sample.kind], lastLimitSamples[sample.kind]]
                .compactMap { $0 }
                .filter { $0.kind == sample.kind && $0.ts <= sample.ts }
                .max { $0.ts < $1.ts }
            if (lastLimitSamples[sample.kind]?.ts ?? .distantPast) <= sample.ts {
                lastLimitSamples[sample.kind] = sample
            }
            guard let threshold = Self.crossedThreshold(previous: previous, current: sample) else { continue }
            let id = Self.limitID(sample, threshold: threshold)
            guard postedLimitAlerts[id] == nil, preferences.enabled, preferences.limitAlerts,
                  !isQuiet(at: now) else { continue }
            postedLimitAlerts[id] = sample.resetsAt ?? now
            actions.post.append(Self.limitRequest(sample, threshold: threshold, id: id, now: now))
        }
        return actions
    }

    public static func crossedThreshold(previous: LimitSample?, current: LimitSample,
                                        thresholds: [Double] = limitThresholds) -> Double? {
        let floor = previous.flatMap { current.isSameWindow(as: $0) ? $0.utilization : nil } ?? -.infinity
        return thresholds.filter { floor < $0 && $0 <= current.utilization }.max()
    }

    public static func limitID(_ sample: LimitSample, threshold: Double) -> String {
        let window = sample.resetsAt.map { String(Int(($0.timeIntervalSince1970 / 600).rounded()) * 600) } ?? "none"
        return "limit:\(sample.kind.rawValue):\(window):\(Int(threshold))"
    }

    private static func limitRequest(_ sample: LimitSample, threshold: Double, id: String,
                                     now: Date) -> NotificationRequest {
        let percent = Int(sample.utilization.rounded(.down))
        let body = sample.resetsAt.map { resetsAt in
            resetsAt > now ? "Resets in \(duration(resetsAt.timeIntervalSince(now)))." : "Resets soon."
        } ?? ""
        return NotificationRequest(id: id, kind: .limit, interruption: threshold >= 95 ? .active : .passive,
                                   title: "Claude \(sample.kind.limitPhrase) at \(percent)%", body: body,
                                   threadID: limitsThreadID)
    }

    // MARK: - Limited sessions

    public static func limitResetID(_ kind: LimitKind, resetsAt: Date) -> String {
        "limit-reset:\(kind.rawValue):\(Int((resetsAt.timeIntervalSince1970 / 600).rounded()) * 600)"
    }

    public mutating func limitedSessionsChecked(_ sessions: [AgentSession], limits: [LimitSample],
                                                localModelPatterns: [String] = [],
                                                now: Date = Date()) -> NotificationActions {
        var blocked: [(session: SessionKey, window: LimitSample)] = []
        for session in sessions {
            if let window = LimitedSessions.blockingWindow(for: session, limits: limits,
                                                           localModelPatterns: localModelPatterns, now: now) {
                blocked.append((session.key, window))
            }
        }
        if let last = blocked.max(by: { ($0.window.resetsAt ?? now) < ($1.window.resetsAt ?? now) }),
           let resetsAt = last.window.resetsAt {
            limitedWatch = LimitedWatch(kind: last.window.kind, resetsAt: resetsAt, sessions: Set(blocked.map(\.session)))
            return NotificationActions()
        }
        guard let watch = limitedWatch else { return NotificationActions() }
        let waiting = sessions.filter { watch.sessions.contains($0.key) && $0.state == .yourTurn && !$0.awaitsInput }
        guard !waiting.isEmpty else {
            limitedWatch = nil
            return NotificationActions()
        }
        // Without a reading (limits switched off, a failed fetch) only the clock can tell.
        let newest = limits.filter { $0.kind == watch.kind }.max { $0.ts < $1.ts }
        guard now >= watch.resetsAt || newest != nil else { return NotificationActions() }
        limitedWatch = nil

        let id = Self.limitResetID(watch.kind, resetsAt: watch.resetsAt)
        postedLimitAlerts = postedLimitAlerts.filter { now.timeIntervalSince($0.value) < 86_400 }
        guard postedLimitAlerts[id] == nil, preferences.enabled, preferences.limitAlerts, !isQuiet(at: now) else {
            return NotificationActions()
        }
        postedLimitAlerts[id] = now
        let body: String
        if waiting.count == 1, let session = waiting.first {
            let name = Self.nonEmpty(session.title) ?? Self.nonEmpty(session.project) ?? "Your session"
            body = "\(name) can continue."
        } else {
            body = "\(waiting.count) sessions can continue."
        }
        return NotificationActions(post: [NotificationRequest(
            id: id, kind: .limit, interruption: .active, title: "Claude \(watch.kind.limitPhrase) reset", body: body,
            threadID: Self.limitsThreadID, session: waiting.count == 1 ? waiting.first?.key : nil, cause: .limitReset)])
    }

    // MARK: - Local model

    public mutating func localModelChecked(server raw: String?, name: String? = nil, online: Bool,
                                           now: Date = Date()) -> NotificationActions {
        let server = Self.nonEmpty(raw?.trimmingCharacters(in: .whitespacesAndNewlines))
        var actions = NotificationActions()
        if server != localModel.server {
            if localModel.alerted { actions.withdraw.append(Self.localModelOfflineID) }
            localModel = LocalModelWatch(server: server)
        }
        guard let server else { return actions }
        let gap = localModel.lastCheck.map { now.timeIntervalSince($0) } ?? 0
        localModel.lastCheck = now

        if online {
            if localModel.alerted { actions.withdraw.append(Self.localModelOfflineID) }
            localModel.seenOnline = true
            localModel.offlineSince = nil
            localModel.alerted = false
            return actions
        }
        guard localModel.seenOnline, !localModel.alerted else { return actions }
        let since = gap > Self.offlineCheckGap ? now : localModel.offlineSince ?? now
        localModel.offlineSince = since
        let down = now.timeIntervalSince(since)
        guard down >= Self.offlineAlertAfter, preferences.enabled, preferences.localModelAlerts,
              !isQuiet(at: now) else { return actions }
        localModel.alerted = true

        let url = URL(string: server)
        let host = url?.host().map { host in url?.port.map { "\(host):\($0)" } ?? host } ?? server
        actions.post.append(NotificationRequest(
            id: Self.localModelOfflineID, kind: .localModelOffline, interruption: .active,
            title: "\(Self.nonEmpty(name?.trimmingCharacters(in: .whitespaces)) ?? "Local model") is offline",
            body: "No response from \(host) for \(Self.duration(down)).", threadID: Self.localModelThreadID))
        return actions
    }

    // MARK: - Helpers

    private static func place(of session: AgentSession, project: ProjectRef?) -> String? {
        nonEmpty(project?.root).map(normalized) ?? nonEmpty(session.cwd).map(normalized)
    }

    private static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded(.up)), 1)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        return hours % 24 == 0 ? "\(hours / 24) d" : "\(hours / 24) d \(hours % 24) h"
    }
}

private extension LimitKind {
    var limitPhrase: String {
        switch self {
        case .fiveHour: return "5-hour limit"
        case .sevenDay: return "weekly limit"
        default: return "weekly \(scopeName) limit"
        }
    }
}
