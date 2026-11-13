import Foundation

public struct PendingUpdate: Equatable, Sendable {
    public enum Stage: String, Sendable {
        case available
        case ready
    }

    public var version: String
    public var stage: Stage

    public init(version: String, stage: Stage) {
        self.version = version
        self.stage = stage
    }
}

public struct UpdateReminder: Equatable, Sendable {
    public private(set) var pending: PendingUpdate?
    public private(set) var hiddenUntil: Date?
    public private(set) var notifiedVersion: String?
    private var withdrawals: [String] = []

    public init(notifiedVersion: String? = nil, runningVersion: String? = nil) {
        self.notifiedVersion = notifiedVersion
        if let notifiedVersion, notifiedVersion == runningVersion {
            withdrawals = [Self.notificationID(notifiedVersion)]
        }
    }

    public var showsBadge: Bool { pending != nil }
    public var showsCard: Bool { pending != nil && hiddenUntil == nil }

    public mutating func found(_ update: PendingUpdate, seen: Bool = false) {
        pending = update
        hiddenUntil = nil
        if seen { notifiedVersion = update.version }
    }

    public mutating func later(until date: Date) {
        guard pending != nil else { return }
        hiddenUntil = date
    }

    public mutating func clear() {
        if let pending { withdrawals.append(Self.notificationID(pending.version)) }
        pending = nil
        hiddenUntil = nil
    }

    public mutating func tick(now: Date, notify: Bool) -> NotificationActions {
        if let hiddenUntil, now >= hiddenUntil { self.hiddenUntil = nil }
        var actions = NotificationActions(withdraw: withdrawals)
        withdrawals = []
        if notify, let pending, pending.version != notifiedVersion {
            notifiedVersion = pending.version
            actions.post = [Self.request(for: pending)]
        }
        return actions
    }

    public static func notificationID(_ version: String) -> String { "update:\(version)" }

    public static func headline(_ update: PendingUpdate) -> String {
        switch update.stage {
        case .ready: return "Hoply \(update.version) is ready to install"
        case .available: return "Hoply \(update.version) is available"
        }
    }

    public static func request(for update: PendingUpdate) -> NotificationRequest {
        let body = switch update.stage {
        case .ready: "Click to restart Hoply now. Otherwise it installs the next time Hoply quits."
        case .available: "Click to see what's new and install it."
        }
        return NotificationRequest(id: notificationID(update.version), kind: .update, interruption: .passive,
                                   title: headline(update), body: body, threadID: "update")
    }
}
