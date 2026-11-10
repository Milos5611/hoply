import Foundation

public enum NotificationKind: String, Sendable, Hashable {
    case permission
    case yourTurn = "your-turn"
    case limit
    case localModelOffline = "local-model-offline"
}

/// Mirrors `UNNotificationInterruptionLevel`. There is no time-sensitive level: it needs an entitlement the
/// ad-hoc signed app does not have.
public enum NotificationInterruption: String, Sendable {
    case active
    case passive
}

public struct NotificationRequest: Sendable, Equatable, Identifiable {
    /// Stable per subject, so a newer request replaces the older one in Notification Center.
    public var id: String
    public var kind: NotificationKind
    public var interruption: NotificationInterruption
    public var title: String
    public var body: String
    public var threadID: String
    /// The session to open when the notification is clicked.
    public var session: SessionKey?

    public init(id: String, kind: NotificationKind, interruption: NotificationInterruption, title: String,
                body: String, threadID: String, session: SessionKey? = nil) {
        self.id = id
        self.kind = kind
        self.interruption = interruption
        self.title = title
        self.body = body
        self.threadID = threadID
        self.session = session
    }

    public var playsSound: Bool { interruption == .active }
}

/// What the app should do in Notification Center: post these, remove those (delivered ids).
public struct NotificationActions: Sendable, Equatable {
    public var post: [NotificationRequest]
    public var withdraw: [String]

    public init(post: [NotificationRequest] = [], withdraw: [String] = []) {
        self.post = post
        self.withdraw = withdraw
    }

    public var isEmpty: Bool { post.isEmpty && withdraw.isEmpty }
}

/// Minutes after local midnight; `start > end` wraps midnight, `start == end` is never quiet.
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
    /// Nil when quiet hours are off.
    public var quietHours: QuietHours?
    /// Silences session notifications only; matched exactly against the project root, or the cwd if unresolved.
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

/// Decides which notifications to post and which to withdraw. A value type with its own memory (cooldowns,
/// limit crossings, local-model outage), owned by the app on the main actor; it posts nothing itself.
public struct NotificationPolicy: Sendable {
    public var preferences: NotificationPreferences
    /// Quiet hours are read in this calendar's time zone.
    public var calendar: Calendar

    /// At most one notification per session and kind in this interval.
    public static let cooldown: TimeInterval = 120
    /// Your-turn only after this much work, so quick back-and-forth in a terminal you're watching stays quiet.
    public static let minimumWork: TimeInterval = 30
    public static let limitThresholds: [Double] = [80, 95]
    public static let offlineAlertAfter: TimeInterval = 120
    public static let localModelOfflineID = "local-model:offline"
    public static let limitsThreadID = "limits"
    public static let localModelThreadID = "local-model"

    private struct Cooldown: Hashable {
        var session: SessionKey
        var kind: NotificationKind
    }

    private struct LocalModelWatch {
        var server: String?
        var seenOnline = false
        var offlineSince: Date?
        var alerted = false
    }

    private var lastPosted: [Cooldown: Date] = [:]
    private var lastLimitSamples: [LimitKind: LimitSample] = [:]
    /// Limit alerts posted this run (id → when its window resets), so a dip and re-rise inside one window
    /// cannot post the same threshold twice.
    private var postedLimitAlerts: [String: Date] = [:]
    private var localModel = LocalModelWatch()

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
        guard let place = Self.place(of: session, project: project) else { return false }
        return preferences.mutedProjectRoots.contains { Self.normalized($0) == place }
    }

    // MARK: - Sessions

    /// Feed every `StateChange` from `SessionBoard.apply` and `tick`. `project` is the session cwd's ledger
    /// project when resolved; it names the notification, threads it and decides muting.
    public mutating func sessionChanged(_ change: StateChange, project: ProjectRef? = nil,
                                        now: Date = Date()) -> NotificationActions {
        let session = change.session
        let id = Self.notificationID(for: session.key)
        var actions = NotificationActions()
        if let from = change.from, from.needsAttention, !change.to.needsAttention {
            actions.withdraw.append(id)
        }
        lastPosted = lastPosted.filter { now.timeIntervalSince($0.value) < Self.cooldown }

        guard change.from != change.to, let kind = Self.kind(of: change) else { return actions }
        let cooldown = Cooldown(session: session.key, kind: kind)
        guard preferences.enabled, !isQuiet(at: now), !isMuted(session, project: project),
              lastPosted[cooldown] == nil else { return actions }
        lastPosted[cooldown] = now

        let source = session.key.source.displayName
        let projectTitle = project?.title ?? session.project
        actions.post.append(NotificationRequest(
            id: id, kind: kind, interruption: kind == .permission ? .active : .passive,
            title: kind == .permission ? "\(source) needs permission" : "\(source) is waiting for you",
            body: [session.title, projectTitle].compactMap { Self.nonEmpty($0) }.joined(separator: " · "),
            threadID: Self.place(of: session, project: project) ?? session.key.source.rawValue,
            session: session.key))
        return actions
    }

    /// The user removed the session from the panel; its notification goes too.
    public mutating func sessionDismissed(_ key: SessionKey) -> NotificationActions {
        NotificationActions(withdraw: [Self.notificationID(for: key)])
    }

    private static func kind(of change: StateChange) -> NotificationKind? {
        switch change.to {
        case .needsPermission:
            return .permission
        case .yourTurn where change.from == .working && change.previousDuration >= minimumWork:
            return .yourTurn
        default:
            return nil
        }
    }

    // MARK: - Claude limits

    /// Feed each fetch's samples (`ClaudeLimits.samples(at:)`). `previous` is each kind's last stored sample from
    /// before this fetch (`Ledger.recordLimits` returns it), so a restart neither repeats nor misses an alert;
    /// pass nil when the ledger is unavailable and the policy relies on what it saw this run.
    ///
    /// A threshold alerts when crossed inside one window (previous < threshold ≤ current), or when a new window
    /// already starts at or above it. Only the highest threshold crossed by one sample posts.
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

    /// `resetsAt` is rounded to 10 minutes so the API's jitter keeps the id stable for one window.
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

    // MARK: - Local model

    /// Feed every model-server poll. `server` is the configured base URL (nil or blank = none configured).
    /// Alerts once per outage of at least `offlineAlertAfter`, and only after the server was seen online this
    /// run, so launching with the server off stays quiet. An alert held back by quiet hours or switched-off
    /// preferences posts once they allow it, if the server is still offline.
    public mutating func localModelChecked(server raw: String?, name: String? = nil, online: Bool,
                                           now: Date = Date()) -> NotificationActions {
        let server = Self.nonEmpty(raw?.trimmingCharacters(in: .whitespacesAndNewlines))
        var actions = NotificationActions()
        if server != localModel.server {
            if localModel.alerted { actions.withdraw.append(Self.localModelOfflineID) }
            localModel = LocalModelWatch(server: server)
        }
        guard let server else { return actions }

        if online {
            if localModel.alerted { actions.withdraw.append(Self.localModelOfflineID) }
            localModel.seenOnline = true
            localModel.offlineSince = nil
            localModel.alerted = false
            return actions
        }
        guard localModel.seenOnline, !localModel.alerted else { return actions }
        let since = localModel.offlineSince ?? now
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

    /// "45 min", "2 h 10 min", "3 d 4 h"; rounded up to the minute.
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
