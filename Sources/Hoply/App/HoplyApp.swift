import AppKit
import SwiftUI

@main
struct HoplyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--snapshot") {
            let directory = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "build/snapshots"
            Snapshot.render(to: URL(fileURLWithPath: directory))
            exit(0)
        }

        statusItem = StatusItemController(model: AppModel())
    }
}
