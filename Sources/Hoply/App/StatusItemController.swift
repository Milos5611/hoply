import AgentKit
import AppKit
import Observation
import SwiftUI

final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let dashboard: DashboardWindowController
    private let palette: PaletteWindowController
    private let idleImage = HoplyMark.statusBarImage(hollowHub: true)
    private let activeImage = HoplyMark.statusBarImage(hollowHub: false)
    private let idleBadgedImage = HoplyMark.statusBarImage(hollowHub: true, badged: true)
    private let activeBadgedImage = HoplyMark.statusBarImage(hollowHub: false, badged: true)

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
        palette = PaletteWindowController(model: model)
        super.init()
        model.paletteToggler = { [weak self] in self?.togglePalette() }
        model.dashboardOpener = { [weak self] page in self?.openDashboard(page) }
        model.panelOpener = { [weak self] in
            self?.model.showingSettings = false
            self?.showPanel()
        }
        model.settingsOpener = { [weak self] in
            self?.model.showingSettings = true
            self?.showPanel()
        }
        model.updates.onWillShowUpdate = { [weak self] in
            if self?.popover.isShown == true { self?.popover.performClose(nil) }
        }
        popover.behavior = Self.holdOpen ? .applicationDefined : .transient
        popover.animates = true
        popover.delegate = self
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

    func togglePalette() {
        if popover.isShown { popover.performClose(nil) }
        palette.toggle()
    }

    func openDashboard(_ page: DashboardPage? = nil) {
        if popover.isShown { popover.performClose(nil) }
        dashboard.show(page)
    }

    func popoverWillShow(_ notification: Notification) {
        model.setPanelOnScreen(true)
    }

    func popoverDidClose(_ notification: Notification) {
        model.setPanelOnScreen(false)
        model.showingSettings = false
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
        menu.autoenablesItems = false
        menu.addItem(item("Open Hoply", #selector(openPanel)))
        menu.addItem(item("Open Dashboard", #selector(openDashboardFromMenu)))
        if model.settings.paletteEnabled {
            menu.addItem(item("Command Palette", #selector(openPalette)))
        }
        menu.addItem(item("Settings…", #selector(openSettings)))
        if model.updates.isEnabled {
            let update = item(Self.updateMenuTitle(model.updates.pending), #selector(runUpdate))
            update.isEnabled = model.updates.canUpdate
            menu.addItem(update)
        }
        menu.addItem(.separator())
        if let version = model.updates.runningVersion {
            let about = NSMenuItem(title: "Version \(version)", action: nil, keyEquivalent: "")
            about.isEnabled = false
            menu.addItem(about)
        }
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

    @objc private func openPalette() {
        palette.show()
    }

    @objc private func openSettings() {
        model.showingSettings = true
        showPanel()
    }

    @objc private func runUpdate() {
        model.updates.update()
    }

    static func updateMenuTitle(_ update: PendingUpdate?) -> String {
        guard let update else { return "Check for Updates…" }
        switch update.stage {
        case .ready: return "Restart to Install Hoply \(update.version)"
        case .available: return "Update to Hoply \(update.version)…"
        }
    }

    @objc private func quit() {
        model.quit()
    }

    private func observeLabel() {
        withObservationTracking {
            updateLabel(attention: model.attentionCount, working: model.workingCount, update: model.updates.pending)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLabel() }
        }
    }

    private func updateLabel(attention: Int, working: Int, update: PendingUpdate?) {
        guard let button = statusItem.button else { return }
        let active = attention > 0 || working > 0
        if update == nil {
            button.image = active ? activeImage : idleImage
        } else {
            button.image = active ? activeBadgedImage : idleBadgedImage
        }
        button.title = attention > 0 ? "\(attention)" : ""
        let note = update.map(UpdateReminder.headline)
        button.toolTip = note
        button.setAccessibilityLabel(note)
    }
}
