import AgentKit
import AppKit
import Observation
import Sparkle

@Observable
final class Updates: NSObject {
    static let notifiedVersionKey = "HoplyUpdateNotifiedVersion"
    static let feedFailureKey = "HoplyUpdateFeedFailure"
    static let changelog = URL(string: "https://hoply.dev/changelog")!
    private static let minimumCheckInterval: TimeInterval = 3600

    private(set) var isEnabled = false
    private(set) var canCheck = false
    private(set) var automaticallyChecks = false
    private(set) var automaticallyDownloads = false
    private(set) var allowsAutomaticDownloads = false
    private(set) var reminder = UpdateReminder()
    private(set) var startError: String?
    private(set) var feedHealth = UpdateFeedHealth()

    @ObservationIgnored var onWillShowUpdate: (() -> Void)?
    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    var pending: PendingUpdate? { reminder.pending }
    var cardUpdate: PendingUpdate? { reminder.showsCard ? reminder.pending : nil }
    var canUpdate: Bool { pending?.stage == .ready || canCheck }
    var feedFailure: UpdateFeedFailure? { feedHealth.failure }

    let runningVersion: String?

    private static var shortVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    var version: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(Self.shortVersion ?? "?") (\(build))"
    }

    init(live: Bool) {
        // Preview models get none, so --snapshot PNGs (the site's screenshots) never show a version that goes stale.
        runningVersion = live ? Self.shortVersion : nil
        super.init()
        guard live, Bundle.main.bundleURL.pathExtension == "app",
              UpdateFeed(info: Bundle.main.infoDictionary ?? [:]) != nil else { return }
        reminder = UpdateReminder(notifiedVersion: UserDefaults.standard.string(forKey: Self.notifiedVersionKey),
                                  runningVersion: runningVersion)
        feedHealth = UpdateFeedHealth(failure: .decoded(UserDefaults.standard.data(forKey: Self.feedFailureKey)))
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                 userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: self), delegate: self)
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
        readSettings()
    }

    func update() {
        if pending?.stage == .ready, let installNow {
            installNow()
        } else {
            checkForUpdates()
        }
    }

    func checkForUpdates() {
        guard let updater else { return }
        onWillShowUpdate?()
        NSApp.activate()
        updater.checkForUpdates()
    }

    func later() {
        reminder.later(until: Date().addingTimeInterval(max(updater?.updateCheckInterval ?? 0, Self.minimumCheckInterval)))
    }

    func tick(now: Date, notify: Bool) -> NotificationActions {
        var next = reminder
        let actions = next.tick(now: now, notify: notify)
        guard next != reminder else { return actions }
        if next.notifiedVersion != reminder.notifiedVersion {
            UserDefaults.standard.set(next.notifiedVersion, forKey: Self.notifiedVersionKey)
        }
        reminder = next
        return actions
    }

    func setAutomaticallyChecks(_ on: Bool) {
        updater?.automaticallyChecksForUpdates = on
        readSettings()
    }

    func setAutomaticallyDownloads(_ on: Bool) {
        updater?.automaticallyDownloadsUpdates = on
        readSettings()
    }

    private func recordFeed(_ change: (inout UpdateFeedHealth) -> Void) {
        var next = feedHealth
        change(&next)
        guard next != feedHealth else { return }
        if next.failure != feedHealth.failure {
            UserDefaults.standard.set(next.failure?.encoded(), forKey: Self.feedFailureKey)
        }
        feedHealth = next
    }

    private func readSettings() {
        guard let updater else { return }
        automaticallyChecks = updater.automaticallyChecksForUpdates
        allowsAutomaticDownloads = updater.allowsAutomaticUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
    }

    func showPreview(enabled: Bool, pending: PendingUpdate? = nil, automaticallyDownloads: Bool = false,
                     feedFailure: UpdateFeedFailure? = nil) {
        isEnabled = enabled
        canCheck = enabled
        automaticallyChecks = enabled
        allowsAutomaticDownloads = enabled
        self.automaticallyDownloads = enabled && automaticallyDownloads
        reminder = UpdateReminder()
        if let pending { reminder.found(pending) }
        feedHealth = UpdateFeedHealth(failure: feedFailure)
    }
}

// Only SPUAutomaticUpdateDriver calls willInstallUpdateOnQuit, after a silent download with automaticallyDownloadsUpdates
// on. Returning true stalls Sparkle's cycle until the block runs or Hoply quits, when Sparkle installs it anyway.
extension Updates: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        reminder.found(PendingUpdate(version: item.displayVersionString, stage: .ready))
        return true
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        switch choice {
        case .skip:
            installNow = nil
            reminder.clear()
        case .dismiss:
            later()
        default:
            break
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        installNow = nil
        reminder.clear()
    }

    // In Sparkle's safe mode (a feed signature failing for 20 days) the appcast still loads, unverified.
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        recordFeed { $0.appcastLoaded(verified: appcast.signingValidationStatus != .failed) }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        recordFeed { $0.checkFailed(error as NSError, at: Date()) }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        recordFeed { $0.cycleEnded() }
    }
}

// Hoply has no Dock icon, so a scheduled check that finds an update never opens Sparkle's window on its own:
// the menu bar dot, the panel card and one notification offer it, and Sparkle shows it when the user clicks one.
extension Updates: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if handleShowingUpdate { NSApp.activate() }
        reminder.found(PendingUpdate(version: update.displayVersionString, stage: .available), seen: handleShowingUpdate)
    }
}
