import AppKit
import Observation
import SwiftUI

/// Owns the menu bar item and the panel popover. Replaces `MenuBarExtra`, which can't be opened or
/// closed from code and draws its own opaque window.
final class StatusItemController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let dashboard: DashboardWindowController

    /// `.transient` closes the panel the moment Hoply resigns active, so Spotlight or the screen-capture
    /// toolbar makes it vanish mid-recording. `HOPLY_HOLD_OPEN=1` keeps it up until the status item is
    /// clicked again; Esc no longer dismisses it in that mode.
    private static let holdOpen: Bool = {
        guard let value = ProcessInfo.processInfo.environment["HOPLY_HOLD_OPEN"] else { return false }
        return !["", "0", "false"].contains(value.lowercased())
    }()

    init(model: AppModel) {
        self.model = model
        dashboard = DashboardWindowController(model: model)
        super.init()
        model.dashboardOpener = { [weak self] page in self?.openDashboard(page) }
        popover.behavior = Self.holdOpen ? .applicationDefined : .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 448, height: 600)
        popover.contentViewController = NSHostingController(rootView: PanelView().environment(model))
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        observeLabel()
    }

    func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let button = statusItem.button else { return }
        // An accessory app has to be active for the popover to become key, otherwise text fields ignore typing.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func openDashboard(_ page: DashboardPage? = nil) {
        if popover.isShown { popover.performClose(nil) }
        dashboard.show(page)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(item("Open Hoply", #selector(openPanel)))
        menu.addItem(item("Open Dashboard", #selector(openDashboardFromMenu)))
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Hoply", #selector(quit)))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openPanel() {
        model.showingSettings = false
        showPanel()
    }

    @objc private func openDashboardFromMenu() {
        openDashboard()
    }

    @objc private func openSettings() {
        model.showingSettings = true
        showPanel()
    }

    @objc private func quit() {
        model.quit()
    }

    private func observeLabel() {
        withObservationTracking {
            updateLabel(attention: model.attentionCount, working: model.workingCount)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLabel() }
        }
    }

    private func updateLabel(attention: Int, working: Int) {
        guard let button = statusItem.button else { return }
        let symbol = attention > 0 || working > 0 ? "circle.hexagongrid.fill" : "circle.hexagongrid"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Hoply")
        image?.isTemplate = true
        button.image = image
        button.title = attention > 0 ? "\(attention)" : ""
    }
}
