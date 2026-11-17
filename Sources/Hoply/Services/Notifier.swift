import AgentKit
import Foundation
import UserNotifications

nonisolated enum NotificationTarget: Sendable, Equatable {
    case session(SessionKey)
    case limits
    case localModel
    case update
    case panel

    static let kindKey = "kind"
    static let sourceKey = "source"
    static let sessionKey = "session"

    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Self.kindKey] as? String, let kind = NotificationKind(rawValue: raw) else {
            return nil
        }
        switch kind {
        case .permission, .yourTurn:
            guard let source = (userInfo[Self.sourceKey] as? String).flatMap(AgentSource.init(rawValue:)),
                  let id = userInfo[Self.sessionKey] as? String else { return nil }
            self = .session(SessionKey(source: source, id: id))
        case .limit:
            self = .limits
        case .localModelOffline:
            self = .localModel
        case .update:
            self = .update
        }
    }
}

/// UNUserNotificationCenter needs a bundle identifier and crashes in a bare `swift run` executable,
/// so this is a no-op outside the bundled .app.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((NotificationTarget) -> Void)?
    var onDecision: ((String, ApprovalDecision) -> Void)?
    var onReply: ((String, String) -> Void)?
    var onFinishReply: ((String) -> Void)?
    private var queue: Task<Void, Never>?
    private let enabled: Bool

    private nonisolated static let approvalCategory = "hoply.approval"
    private nonisolated static let allowAction = "hoply.allow"
    private nonisolated static let denyAction = "hoply.deny"
    private nonisolated static let approvalKey = "approval"
    private nonisolated static let replyCategory = "hoply.reply"
    private nonisolated static let replyAction = "hoply.reply.send"
    private nonisolated static let doneAction = "hoply.reply.done"
    private nonisolated static let replyKey = "reply"

    static func replyNotificationID(_ id: String) -> String {
        "reply:\(id)"
    }

    private nonisolated static func replyCategory(for source: AgentSource) -> String {
        "\(replyCategory).\(source.rawValue)"
    }

    init(enabled: Bool = true) {
        self.enabled = enabled
        super.init()
    }

    private var isAvailable: Bool {
        enabled && Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Must run before launch finishes, so a click that launched the app still reaches the delegate.
    func activate() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        let done = UNNotificationAction(identifier: Self.doneAction, title: "Done", options: [])
        // The text field's placeholder belongs to the category, so each agent needs its own.
        let replies = TurnReply.sources.map { source in
            let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply",
                                                      options: [.authenticationRequired], textInputButtonTitle: "Send",
                                                      textInputPlaceholder: AwayText.placeholder(source))
            return UNNotificationCategory(identifier: Self.replyCategory(for: source), actions: [reply, done],
                                          intentIdentifiers: [])
        }
        center.setNotificationCategories(Set(replies + [
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, deny], intentIdentifiers: []),
        ]))
    }

    func requestAuthorization() {
        guard isAvailable else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    func post(_ request: NotificationRequest, approval: ApprovalRequest? = nil, reply: TurnReplyRequest? = nil,
              subtitle: String? = nil) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.threadIdentifier = request.threadID
        // Passive requests stay silent but keep the banner: macOS mutes .passive, which hides it entirely.
        content.interruptionLevel = .active
        content.sound = request.playsSound ? .default : nil
        var userInfo: [String: String] = [NotificationTarget.kindKey: request.kind.rawValue]
        if let session = request.session {
            userInfo[NotificationTarget.sourceKey] = session.source.rawValue
            userInfo[NotificationTarget.sessionKey] = session.id
        }
        if let approval {
            content.categoryIdentifier = Self.approvalCategory
            content.body = [approval.summary, request.body].filter { !$0.isEmpty }.joined(separator: "\n")
            userInfo[Self.approvalKey] = approval.id
        }
        if let reply {
            content.categoryIdentifier = Self.replyCategory(for: reply.key.source)
            userInfo[Self.replyKey] = reply.id
        }
        if let subtitle { content.subtitle = subtitle }
        content.userInfo = userInfo
        let notification = UNNotificationRequest(identifier: request.id, content: content, trigger: nil)
        enqueue { try? await UNUserNotificationCenter.current().add(notification) }
    }

    func withdraw(_ ids: [String]) {
        guard isAvailable, !ids.isEmpty else { return }
        enqueue {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Posts and withdrawals reach the notification center in call order: `add` is asynchronous, so a
    /// withdrawal issued right after a post would otherwise run first and leave the notification up.
    private func enqueue(_ operation: @escaping () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await operation()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        switch response.actionIdentifier {
        case Self.allowAction, Self.denyAction:
            guard let id = userInfo[Self.approvalKey] as? String else { return }
            let decision: ApprovalDecision = response.actionIdentifier == Self.allowAction ? .allow : .deny
            await MainActor.run { onDecision?(id, decision) }
        case Self.replyAction:
            guard let id = userInfo[Self.replyKey] as? String,
                  let text = (response as? UNTextInputNotificationResponse)?.userText else { return }
            await MainActor.run { onReply?(id, text) }
        case Self.doneAction:
            guard let id = userInfo[Self.replyKey] as? String else { return }
            await MainActor.run { onFinishReply?(id) }
        case UNNotificationDefaultActionIdentifier:
            let target = userInfo[Self.replyKey] == nil ? NotificationTarget(userInfo: userInfo) : .panel
            guard let target else { return }
            await MainActor.run { onOpen?(target) }
        default:
            break
        }
    }
}
