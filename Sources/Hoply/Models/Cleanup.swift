import AgentKit
import AgentSystem
import Foundation
import Observation

@MainActor
@Observable
final class Cleanup {
    struct Context {
        var activity: CleanupActivity
        var thresholds: CleanupRules.Thresholds
    }

    static let firstScanDelay: Duration = .seconds(120)
    static let scanInterval: Duration = .seconds(86_400)
    static let logLimit = 12

    private(set) var scan: CleanupScan?
    private(set) var orphans: [OrphanProcess] = []
    private(set) var selection: Set<String> = []
    private(set) var isScanning = false
    private(set) var isRunning = false
    private(set) var report: CleanupReport?
    private(set) var log: [CleanupLogEntry] = []
    var isReviewing = false
    @ObservationIgnored var context: (() -> Context?)?

    @ObservationIgnored private let service: CleanupService?
    @ObservationIgnored private let history: History
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private var hasUserScanned = false
    @ObservationIgnored private var offered: Set<String> = []

    init(history: History, live: Bool = true) {
        self.history = history
        service = live ? CleanupService(trash: WorkspaceTrash()) : nil
    }

    var candidates: [CleanupCandidate] {
        (scan?.candidates ?? []) + orphans.map(CleanupCandidate.init(orphan:))
    }

    var selected: [CleanupCandidate] {
        candidates.filter { $0.isEligible && selection.contains($0.id) }
    }

    var reclaimableBytes: Int64 { scan?.reclaimableBytes ?? 0 }

    var selectedBytes: Int64 { CleanupScan(candidates: selected).reclaimableBytes }

    func candidates(of kind: CleanupKind) -> [CleanupCandidate] {
        candidates.filter { $0.kind == kind }
    }

    func isSelected(_ candidate: CleanupCandidate) -> Bool {
        selection.contains(candidate.id)
    }

    func start() {
        guard service != nil, loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: Self.firstScanDelay)
            while !Task.isCancelled {
                await self?.runScan(byUser: false)
                try? await Task.sleep(for: Self.scanInterval)
            }
        }
    }

    func refresh() {
        Task { await runScan(byUser: true) }
    }

    func observe(_ snapshot: ProcessSnapshot) {
        guard let service else { return }
        Task {
            let current = await service.observe(snapshot)
            if current != orphans { setOrphans(current) }
        }
    }

    func setSelected(_ candidate: CleanupCandidate, _ isOn: Bool) {
        setSelected([candidate], isOn)
    }

    func setSelected(_ candidates: [CleanupCandidate], _ isOn: Bool) {
        let ids = candidates.filter(\.isEligible).map(\.id)
        if isOn { selection.formUnion(ids) } else { selection.subtract(ids) }
    }

    func dismissReport() {
        report = nil
    }

    func run() {
        let chosen = selected
        guard let service, let context = context?(), !isRunning, !chosen.isEmpty else { return }
        isReviewing = false
        isRunning = true
        Task {
            let inventory = await history.cleanupInventory()
            let options = CleanupOptions(thresholds: context.thresholds, includesProtectedFolders: true)
            let report = await service.run(chosen, inventory: inventory, activity: context.activity, options: options)
            await history.logCleanup(report.logEntries)
            self.report = report
            selection.subtract(chosen.map(\.id))
            setOrphans(await service.orphans)
            isRunning = false
            await runScan(byUser: true)
        }
    }

    private func runScan(byUser: Bool) async {
        guard !isScanning else {
            if byUser { rescanRequested = true }
            return
        }
        isScanning = true
        defer { isScanning = false }
        hasUserScanned = hasUserScanned || byUser
        repeat {
            rescanRequested = false
            await performScan()
            hasUserScanned = hasUserScanned || rescanRequested
        } while rescanRequested
    }

    // Folders behind a privacy prompt are read only once the user has asked for a scan; after that every scan
    // includes them, so a later unattended scan does not drop what the user saw.
    private func performScan() async {
        guard let service, let context = context?(), let inventory = await history.cleanupInventory() else {
            scan = nil
            return
        }
        let options = CleanupOptions(thresholds: context.thresholds, includesProtectedFolders: hasUserScanned)
        let result = await service.scan(inventory: inventory, activity: context.activity, options: options)
        scan = result
        log = await history.cleanupLog(limit: Self.logLimit)
        reconcileSelection()
    }

    private func setOrphans(_ current: [OrphanProcess]) {
        orphans = current
        reconcileSelection()
    }

    // A build cache is ticked the first time it is offered; unticking it sticks across later scans.
    private func reconcileSelection() {
        let eligible = candidates.filter(\.isEligible)
        let fresh = eligible.filter { $0.kind == .buildCache && !offered.contains($0.id) }.map(\.id)
        selection = selection.intersection(eligible.map(\.id)).union(fresh)
        offered.formUnion(fresh)
    }
}

extension Cleanup {
    func show(_ scan: CleanupScan?, orphans: [OrphanProcess] = [], report: CleanupReport? = nil,
              log: [CleanupLogEntry] = []) {
        self.scan = scan
        self.orphans = orphans
        self.report = report
        self.log = log
        offered = []
        selection = []
        reconcileSelection()
    }
}
