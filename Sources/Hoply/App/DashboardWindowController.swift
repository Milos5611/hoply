import AppKit
import SwiftUI

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
        model.setDashboardOnScreen(true)
    }

    func windowWillClose(_ notification: Notification) {
        model.history.setDashboardVisible(false)
        model.setDashboardOnScreen(false)
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateOnScreen()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        updateOnScreen()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updateOnScreen()
    }

    /// A miniaturized window reports `isVisible == false`, so that can't be a reason to skip the update.
    private func updateOnScreen() {
        guard let window else { return }
        model.setDashboardOnScreen(window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible))
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
