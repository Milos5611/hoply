import AgentKit
import Foundation
import UserNotifications

/// Local notifications. Only active in the bundled .app: UNUserNotificationCenter
/// needs a bundle identifier and crashes in a bare `swift run` executable.
final class Notifier {
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ session: AgentSession) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        let source = session.key.source.displayName
        content.title = session.state == .needsPermission ? "\(source) needs permission" : "\(source) is waiting for you"
        content.body = [session.title, session.project].compactMap { $0 }.joined(separator: " · ")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "\(session.id)-\(Date().timeIntervalSince1970)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
