import AgentKit
import Foundation
import UserNotifications

nonisolated enum NotificationTarget: Sendable, Equatable {
    case session(SessionKey)
    case limits
    case localModel

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
        }
    }
}

/// UNUserNotificationCenter needs a bundle identifier and crashes in a bare `swift run` executable,
/// so this is a no-op outside the bundled .app.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((NotificationTarget) -> Void)?
    private var queue: Task<Void, Never>?

    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Must run before launch finishes, so a click that launched the app still reaches the delegate.
    func activate() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        guard isAvailable else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    func post(_ request: NotificationRequest) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.threadIdentifier = request.threadID
        content.interruptionLevel = request.interruption == .active ? .active : .passive
        content.sound = request.playsSound ? .default : nil
        var userInfo: [String: String] = [NotificationTarget.kindKey: request.kind.rawValue]
        if let session = request.session {
            userInfo[NotificationTarget.sourceKey] = session.source.rawValue
            userInfo[NotificationTarget.sessionKey] = session.id
        }
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
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let target = NotificationTarget(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { onOpen?(target) }
    }
}
