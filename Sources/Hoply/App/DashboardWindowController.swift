import AppKit
import SwiftUI

/// One reusable Dashboard window. Hoply is an accessory app; while the window is open it becomes a regular
/// app (Dock icon, app switcher, menu bar) so the window behaves like any other, and goes back on close.
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show(_ page: DashboardPage? = nil) {
        if let page { model.history.select(page) }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.history.setDashboardVisible(true)
    }

    func windowWillClose(_ notification: Notification) {
        model.history.setDashboardVisible(false)
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: DashboardView().environment(model))
        controller.sceneBridgingOptions = [.toolbars, .title]
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "Hoply"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 1120, height: 740))
        if !window.setFrameUsingName("HoplyDashboard") { window.center() }
        window.setFrameAutosaveName("HoplyDashboard")
        return window
    }
}
