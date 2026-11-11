import AgentKit
import AppKit
import Observation
import Sparkle

@Observable
final class Updates: NSObject {
    private(set) var isEnabled = false
    private(set) var canCheck = false
    private(set) var automaticallyChecks = false
    private(set) var pendingVersion: String?
    private(set) var startError: String?

    @ObservationIgnored var onWillShowUpdate: (() -> Void)?
    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    init(live: Bool) {
        super.init()
        guard live, Bundle.main.bundleURL.pathExtension == "app",
              UpdateFeed(info: Bundle.main.infoDictionary ?? [:]) != nil else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                 userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: self), delegate: nil)
        do {
            try updater.start()
        } catch {
            startError = error.localizedDescription
            return
        }
        // Only right after start(): Sparkle's own cycle begins on the next run loop turn and would drop a later call.
        if updater.automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        }
        self.updater = updater
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
        }
        isEnabled = true
        automaticallyChecks = updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        guard let updater else { return }
        onWillShowUpdate?()
        NSApp.activate()
        updater.checkForUpdates()
    }

    func setAutomaticallyChecks(_ on: Bool) {
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = on
        automaticallyChecks = updater.automaticallyChecksForUpdates
    }

    func showPreview(enabled: Bool, pendingVersion: String?) {
        isEnabled = enabled
        canCheck = enabled
        automaticallyChecks = enabled
        self.pendingVersion = pendingVersion
    }
}

// Hoply has no Dock icon, so a scheduled check that finds an update never opens Sparkle's window on its own:
// the panel footer offers it instead, and Sparkle shows it when the user clicks there or checks by hand.
extension Updates: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if handleShowingUpdate {
            NSApp.activate()
        } else {
            pendingVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
