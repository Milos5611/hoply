import AppKit
import SwiftUI

@main
struct HoplyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(attention: model.attentionCount, working: model.workingCount)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no app switcher entry (also when run with `swift run`).
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarLabel: View {
    let attention: Int
    let working: Int

    var body: some View {
        if attention > 0 {
            HStack(spacing: 2) {
                Image(systemName: "circle.hexagongrid.fill")
                Text("\(attention)")
            }
        } else {
            Image(systemName: working > 0 ? "circle.hexagongrid.fill" : "circle.hexagongrid")
        }
    }
}
