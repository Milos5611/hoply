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
    private var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.applicationIconImage = HoplyMark.appIconImage()
        }

        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--snapshot") {
            let directory = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "build/snapshots"
            Snapshot.render(to: URL(fileURLWithPath: directory))
            exit(0)
        }

        let model = AppModel()
        self.model = model
        let controller = StatusItemController(model: model)
        statusItem = controller
        if let surface = ProcessInfo.processInfo.environment["HOPLY_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                switch surface {
                case "panel": controller.showPanel()
                case "dashboard": controller.openDashboard()
                case "palette": controller.togglePalette()
                default: break
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.history.isReady else { return .terminateNow }
        Task {
            await model.history.closeStateSpans(within: .seconds(1))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
