import AgentKit
import AgentSystem
import AppKit
import SwiftUI

enum Snapshot {
    static func render(to directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let now = Date()
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let model = AppModel.preview(now: now)
                let looks = NSAppearance(named: appearance)
                // Stands in for the popover's surface, which only the window server can draw.
                let popover = Color(white: name == "light" ? 0.925 : 0.16)
                try render(PanelView(), model: model, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-\(name).png"))

                var backfilling = PreviewData.history(now: now)
                backfilling.progress = PreviewData.backfilling
                model.history.show(backfilling)
                try render(VStack(spacing: 0) { PanelHeader(); PanelSections().padding(.horizontal, 12); PanelFooter() }
                               .frame(width: 448),
                           model: model, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-full-\(name).png"))
                model.showingSettings = true
                try render(PanelView(), model: model, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-settings-\(name).png"))
                try render(VStack(spacing: 0) { PanelHeader(); SettingsView() }.frame(width: 448, height: 1_880),
                           model: model, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-settings-full-\(name).png"))
                var allPriced = PreviewData.history(now: now)
                allPriced.unpricedModels = []
                model.history.show(allPriced)
                try render(PricingSettings(aliases: .constant([:])).font(.system(size: 12.5)).padding(12).frame(width: 448),
                           model: model, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-settings-pricing-empty-\(name).png"))

                try render(PaletteSettings().toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
                               .padding(12).frame(width: 448),
                           model: model, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-settings-palette-\(name).png"))
                for (state, query) in [("empty", ""), ("query", "fib"), ("actions", ">"), ("no-results", "zzqx")] {
                    model.palette.show(query: query, sessions: PreviewData.paletteSessions(now: now),
                                       projects: PreviewData.paletteProjects(now: now))
                    try render(PaletteView(plainBackground: true).padding(PaletteWindowController.margin),
                               model: model, appearance: looks,
                               to: directory.appendingPathComponent("palette-\(state)-\(name).png"))
                }

                for page in DashboardPage.allCases {
                    var preview = PreviewData.history(now: now)
                    if page == .overview { preview.progress = PreviewData.backfilling }
                    model.history.show(preview, page: page)
                    let height: CGFloat = switch page {
                    case .projects: 980
                    case .sessions: 900
                    case .spending: 1_420
                    case .limits: 1_200
                    case .localModel: 1_560
                    case .cleanUp: 1_180
                    default: 760
                    }
                    try render(DashboardView(plainSidebar: true).frame(width: 1180, height: height),
                               model: model, appearance: looks,
                               to: directory.appendingPathComponent("dashboard-\(page.rawValue)-\(name).png"))
                }
                let servers = PreviewData.devServers(now: now)
                model.devServers.show(servers, stops: PreviewData.devServerStops(servers),
                                      notice: DevServers.Notice(text: "Stopped Astro :4321", isError: false))
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 760), model: model,
                           appearance: looks, to: directory.appendingPathComponent("dashboard-dev-servers-stop-\(name).png"))
                try render(VStack(spacing: 0) { PanelSections().padding(.horizontal, 12); PanelFooter() }.frame(width: 448),
                           model: model, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-dev-servers-stop-\(name).png"))
                model.devServers.show(DevServerScan(snapshot: ProcessSnapshot(takenAt: now, processes: [])))
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 760), model: model,
                           appearance: looks, to: directory.appendingPathComponent("dashboard-dev-servers-empty-\(name).png"))
                model.devServers.show(servers)

                model.history.show(PreviewData.history(now: now), page: .cleanUp)
                model.cleanup.show(PreviewData.cleanupScan(now: now), report: PreviewData.cleanupReport(now: now),
                                   log: PreviewData.cleanupLog(now: now))
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 1_180), model: model,
                           appearance: looks, to: directory.appendingPathComponent("dashboard-clean-up-report-\(name).png"))
                model.cleanup.show(PreviewData.cleanupScan(now: now), orphans: PreviewData.cleanupOrphans(now: now),
                                   log: PreviewData.cleanupLog(now: now))
                model.cleanup.setSelected(model.cleanup.candidates, true)
                try render(CleanupReviewSheet(), model: model, appearance: looks,
                           to: directory.appendingPathComponent("dashboard-clean-up-review-\(name).png"))
                model.cleanup.show(PreviewData.cleanupScan(now: now), orphans: PreviewData.cleanupOrphans(now: now),
                                   log: PreviewData.cleanupLog(now: now))

                var disconnected = PreviewData.settings
                disconnected.claudeLimitsEnabled = false
                disconnected.copilotMonthlyAllowance = 0
                var empty = PreviewData.history(now: now)
                empty.limits?.samples = []
                empty.limits?.projections = [:]
                empty.limits?.copilot.allowance = 0
                model.showPreview(settings: disconnected)
                model.history.show(empty, page: .limits)
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 760), model: model, appearance: looks,
                           to: directory.appendingPathComponent("dashboard-limits-empty-\(name).png"))
                model.showPreview(settings: PreviewData.settings)

                let lastSeen = now.addingTimeInterval(-47 * 60)
                var offline = PreviewData.history(now: now)
                offline.localModel?.generation.removeAll { $0.startDate > lastSeen }
                offline.localModel?.kvCache.removeAll { $0.startDate > lastSeen }
                offline.localModel?.lastSeen = lastSeen
                var down = PreviewData.modelServerStates(now: now)
                down[PreviewData.zgxServer.id]?.availability = .offline
                down[PreviewData.zgxServer.id]?.error = RemoteError(.timedOut, endpoint: PreviewData.zgxServer.displayName)
                down[PreviewData.zgxServer.id]?.lastSeen = lastSeen
                model.modelServers.show(down)
                model.history.show(offline, page: .localModel)
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 1_560), model: model,
                           appearance: looks, to: directory.appendingPathComponent("dashboard-local-model-offline-\(name).png"))

                var noServer = PreviewData.settings
                noServer.modelServers = []
                var unset = PreviewData.history(now: now)
                unset.localModel?.serverID = nil
                unset.localModel?.generation = []
                unset.localModel?.kvCache = []
                unset.localModel?.tokenDays = []
                model.showPreview(settings: noServer)
                model.modelServers.show([:], discovery: .found([]))
                model.history.show(unset, page: .localModel)
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 760), model: model,
                           appearance: looks, to: directory.appendingPathComponent("dashboard-local-model-empty-\(name).png"))
                try render(PanelSections().padding(12).frame(width: 448), model: model, appearance: looks,
                           surface: popover, to: directory.appendingPathComponent("panel-model-servers-none-\(name).png"))

                let states = PreviewData.modelServerStates(now: now)
                model.showPreview(settings: PreviewData.twoServersSettings)
                model.modelServers.show(states)
                model.history.show(PreviewData.history(now: now))
                try render(PanelSections().padding(12).frame(width: 448), model: model, appearance: looks,
                           surface: popover, to: directory.appendingPathComponent("panel-model-servers-\(name).png"))

                model.showPreview(settings: PreviewData.severalServersSettings)
                model.modelServers.show(states, discovery: .found(PreviewData.discovered(now: now)))
                try render(ModelServerSettings().toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
                               .padding(12).frame(width: 448),
                           model: model, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-settings-model-servers-\(name).png"))
                try render(PanelSections().padding(12).frame(width: 448), model: model, appearance: looks,
                           surface: popover, to: directory.appendingPathComponent("panel-model-servers-several-\(name).png"))

                var ollama = PreviewData.history(now: now)
                ollama.localModel = PreviewData.ollamaLocalModel(ollama.localModel)
                model.modelServers.show(states, selected: PreviewData.ollamaServer.id)
                model.history.show(ollama, page: .localModel)
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 1_500), model: model,
                           appearance: looks, to: directory.appendingPathComponent("dashboard-local-model-ollama-\(name).png"))

                var blocked = PreviewData.history(now: now)
                blocked.localModel = PreviewData.ollamaLocalModel(blocked.localModel)
                blocked.localModel?.serverID = PreviewData.teamServer.id
                blocked.localModel?.memory = []
                blocked.localModel?.lastSeen = nil
                model.modelServers.show(states, selected: PreviewData.teamServer.id)
                model.history.show(blocked, page: .localModel)
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 900), model: model,
                           appearance: looks, to: directory.appendingPathComponent("dashboard-local-model-blocked-\(name).png"))

                for (state, failed) in [("ok", false), ("failed", true)] {
                    try render(ModelServerEditorSheet(editor: PreviewData.editor(failed: failed, now: now)), model: model,
                               appearance: looks,
                               to: directory.appendingPathComponent("model-server-editor-\(state)-\(name).png"))
                }

                model.showPreview(settings: PreviewData.settings)
                model.modelServers.show(states)

                model.history.showProjectDetail(PreviewData.history(now: now))
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 1_600), model: model,
                           appearance: looks, to: directory.appendingPathComponent("dashboard-project-detail-\(name).png"))
                let edits = PreviewData.projectEdits(now: now)
                model.projectEdits.beginMerge(PreviewData.projectRefs[0], into: PreviewData.projectRefs[1])
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 1_720), model: model,
                           appearance: looks,
                           to: directory.appendingPathComponent("dashboard-project-detail-merge-\(name).png"))
                model.projectEdits.show(edits, error: ProjectEditText.describe(ProjectEditError.unknownProject(8)))
                model.history.showProjectDetail(PreviewData.history(now: now), unassigned: true)
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 1_280), model: model,
                           appearance: looks,
                           to: directory.appendingPathComponent("dashboard-project-unassigned-\(name).png"))
                model.projectEdits.show(edits)
                model.history.show(PreviewData.history(now: now), page: .projects)
                if let suggestion = edits.suggestions.first { model.projectEdits.beginMerge(suggestion) }
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 1_040), model: model,
                           appearance: looks,
                           to: directory.appendingPathComponent("dashboard-projects-merge-\(name).png"))
                model.projectEdits.show(edits)
                let approving = AppModel.preview(now: now)
                approving.showPreview(approvals: PreviewData.approvals(now: now), events: PreviewData.approvalEvents(now: now))
                try render(PanelView(), model: approving, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-approval-\(name).png"))
                try render(VStack(spacing: 6) {
                    TooltipBubble(text: "Resume this session in Terminal")
                    HStack(spacing: 8) {
                        ForEach(["play.fill", "chevron.left.forwardslash.chevron.right", "doc.text.magnifyingglass",
                                 "apple.terminal", "number"], id: \.self) { symbol in
                            Button {} label: { Image(systemName: symbol) }
                        }
                    }
                    .buttonStyle(.tile)
                }.padding(16).frame(width: 322), model: model, appearance: looks,
                           to: directory.appendingPathComponent("tooltip-\(name).png"))
                try render(VStack(spacing: 12) {
                    ForEach(Array(PreviewData.timelineSamples(now: now).enumerated()), id: \.offset) { _, spans in
                        SessionTimelineCard(spans: spans)
                    }
                }.padding(16).frame(width: 322).background(DashboardBackground()),
                           model: model, appearance: looks,
                           to: directory.appendingPathComponent("session-timeline-\(name).png"))
            }
            print(directory.path)
        } catch {
            FileHandle.standardError.write(Data("Snapshot failed: \(error)\n".utf8))
        }
    }

    private static func render(_ view: some View, model: AppModel, appearance: NSAppearance?,
                               surface: Color = Color(nsColor: .windowBackgroundColor), to file: URL) throws {
        let host = NSHostingView(rootView: view
            .environment(model)
            .background(surface))
        let frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.orderOut(nil)
        try bitmap.representation(using: .png, properties: [:])?.write(to: file)
    }
}
