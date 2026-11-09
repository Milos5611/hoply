import AgentKit
import Foundation
import UserNotifications

/// What a clicked notification should open; built from the notification's `userInfo`.
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
    /// Called on the main actor when the user clicks a notification.
    var onOpen: ((NotificationTarget) -> Void)?

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
        Task { try? await UNUserNotificationCenter.current().add(notification) }
    }

    func withdraw(_ ids: [String]) {
        guard isAvailable, !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Banners also show while the Dashboard is in front.
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
