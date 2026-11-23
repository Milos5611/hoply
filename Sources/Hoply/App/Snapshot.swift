import AgentKit
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
                try render(VStack(spacing: 0) { PanelHeader(); SettingsView() }.frame(width: 448, height: 2_700),
                           model: model, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-settings-full-\(name).png"))
                for (state, statuses, notices) in [("update", PreviewData.connectionsToUpdate, [:]),
                                                   ("unreadable", PreviewData.connectionsUnreadable,
                                                    PreviewData.connectionFailure)] {
                    model.connections.show(statuses: statuses, notices: notices)
                    try render(AgentSettings().controlSize(.small).font(.system(size: 12.5)).padding(12).frame(width: 448),
                               model: model, appearance: looks, surface: popover,
                               to: directory.appendingPathComponent("panel-settings-agents-\(state)-\(name).png"))
                }
                model.connections.show(statuses: PreviewData.connectionStatuses, notices: PreviewData.connectionNotices)
                model.history.show(PreviewData.history(now: now))
                model.showingSettings = false
                #if Sparkle
                model.updates.showPreview(enabled: true, pending: PreviewData.availableUpdate)
                try render(PanelView(), model: model, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-update-\(name).png"))
                try render(UpdateSettings().toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
                               .padding(12).frame(width: 448),
                           model: model, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-settings-updates-\(name).png"))
                model.updates.showPreview(enabled: true, pending: PreviewData.readyUpdate, automaticallyDownloads: true)
                try render(VStack(spacing: 10) {
                    UpdateCard(update: PreviewData.readyUpdate)
                    UpdateSettings().toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
                }.padding(12).frame(width: 448),
                           model: model, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-update-ready-\(name).png"))
                try render(MenuBarMarks(), model: model, appearance: looks,
                           surface: Color(white: name == "light" ? 0.97 : 0.13),
                           to: directory.appendingPathComponent("menu-bar-update-\(name).png"))
                model.updates.showPreview(enabled: false)
                try render(UpdateSettings().controlSize(.small).font(.system(size: 12.5)).padding(12).frame(width: 448),
                           model: model, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-settings-updates-off-\(name).png"))
                model.updates.showPreview(enabled: true)
                #endif
                model.showingSettings = true
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
                for (state, available, status) in PreviewData.iCloudLinkStates(now: now) {
                    var linked = PreviewData.settings
                    linked.iCloudLink = available
                    linked.iPhoneLaunch = status == .running
                    model.showPreview(settings: linked)
                    model.iCloudLink.show(available: available, status: status,
                                          lastSync: status == .running ? now - 12 : nil)
                    try render(PhoneSettings().toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
                                   .padding(12).frame(width: 448),
                               model: model, appearance: looks, surface: popover,
                               to: directory.appendingPathComponent("panel-settings-iphone-\(state)-\(name).png"))
                }
                model.showPreview(settings: PreviewData.settings)
                model.iCloudLink.show(available: false)
                for (state, query) in [("empty", ""), ("query", "core"), ("actions", ">"), ("no-results", "zzqx")] {
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
                    case .limits: 1_520
                    case .localModel: 1_560
                    default: 760
                    }
                    try render(DashboardView(plainSidebar: true).frame(width: 1180, height: height),
                               model: model, appearance: looks,
                               to: directory.appendingPathComponent("dashboard-\(page.rawValue)-\(name).png"))
                }
                for page in [DashboardPage.overview, .spending, .sessions, .projects] {
                    model.history.show(PreviewData.severalMacsHistory(now: now), page: page)
                    let height: CGFloat = switch page {
                    case .projects: 1_120
                    case .sessions: 900
                    case .spending: 1_420
                    default: 760
                    }
                    try render(DashboardView(plainSidebar: true).frame(width: 1180, height: height),
                               model: model, appearance: looks,
                               to: directory.appendingPathComponent("dashboard-\(page.rawValue)-macs-\(name).png"))
                }
                model.history.showProjectDetail(PreviewData.severalMacsHistory(now: now))
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 1_400), model: model,
                           appearance: looks, to: directory.appendingPathComponent("dashboard-project-remote-\(name).png"))
                var disconnected = PreviewData.settings
                disconnected.claudeLimitsEnabled = false
                disconnected.copilotMonthlyAllowance = 0
                var empty = PreviewData.history(now: now)
                empty.limits?.samples = []
                empty.limits?.projections = [:]
                empty.limits?.copilot.allowance = 0
                empty.codexLimits = [:]
                model.showPreview(settings: disconnected)
                model.history.show(empty, page: .limits)
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 760), model: model, appearance: looks,
                           to: directory.appendingPathComponent("dashboard-limits-empty-\(name).png"))
                model.history.show(PreviewData.codexOnlyHistory(now: now), page: .limits)
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 1_080), model: model,
                           appearance: looks, to: directory.appendingPathComponent("dashboard-limits-codex-\(name).png"))
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
                let away = AppModel.preview(now: now)
                away.showPreview(settings: PreviewData.awaySettings)
                away.showPreview(replies: PreviewData.replies(now: now), events: PreviewData.replyEvents(now: now))
                try render(VStack(spacing: 0) { PanelHeader(); PanelSections().padding(.horizontal, 12); PanelFooter() }
                               .frame(width: 448),
                           model: away, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-reply-full-\(name).png"))
                for id in ["schema", "notes"] { away.dismiss(SessionKey(source: .claudeCode, id: id)) }
                away.dismiss(PreviewData.copilotReplySession)
                try render(PanelView(), model: away, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-reply-\(name).png"))
                try render(VStack(spacing: 16) {
                    ForEach([PreviewData.longReplyMessage, PreviewData.replyMessage], id: \.self) { message in
                        ReplyStrip(reply: TurnReplyRequest(key: PreviewData.replySession, message: message,
                                                           received: now - 95),
                                   expanded: true)
                    }
                }.frame(width: 358).padding(12),
                           model: away, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-reply-expanded-\(name).png"))
                for (state, statuses) in [("", PreviewData.connectionStatuses), ("-update", PreviewData.awayTwoOutdated)] {
                    away.connections.show(statuses: statuses)
                    try render(NotificationSettings(settings: .constant(PreviewData.awaySettings))
                                   .toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
                                   .padding(12).frame(width: 448),
                               model: away, appearance: looks, surface: popover,
                               to: directory.appendingPathComponent("panel-settings-away\(state)-\(name).png"))
                }
                let awayBlocked = AppModel.preview(now: now)
                awayBlocked.showPreview(settings: PreviewData.awaySettings)
                awayBlocked.connections.show(statuses: PreviewData.awayOneOutdated)
                try render(VStack(spacing: 0) { PanelHeader(); PanelSections().padding(.horizontal, 12) }.frame(width: 448),
                           model: awayBlocked, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-away-update-\(name).png"))
                try render(PanelView(), model: AppModel.firstRunPreview(), appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-agents-connect-\(name).png"))
                let outdated = AppModel.preview(now: now)
                outdated.connections.show(statuses: PreviewData.connectionsToUpdate)
                try render(VStack(spacing: 0) { PanelHeader(); PanelSections().padding(.horizontal, 12); PanelFooter() }
                               .frame(width: 448),
                           model: outdated, appearance: looks, surface: popover,
                           to: directory.appendingPathComponent("panel-agents-update-\(name).png"))
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
                try renderStore(to: directory, name: name, appearance: looks, surface: popover, now: now)
            }
            try AppStoreShots.render(to: directory, now: now)
            print(directory.path)
        } catch {
            FileHandle.standardError.write(Data("Snapshot failed: \(error)\n".utf8))
        }
    }

    private static func renderStore(to directory: URL, name: String, appearance looks: NSAppearance?, surface popover: Color,
                                    now: Date) throws {
        func file(_ base: String) -> URL { directory.appendingPathComponent("store-\(base)-\(name).png") }
        let store = Edition.appStore

        try render(PanelView().environment(\.edition, store), model: AppModel.storeFirstRunPreview(), appearance: looks,
                   surface: popover, to: file("panel-first-run"))
        let taken = AppModel.storeFirstRunPreview(portInUse: true)
        taken.connections.dismissFolderCard()
        try render(PanelView().environment(\.edition, store), model: taken, appearance: looks, surface: popover,
                   to: file("panel-port-taken"))

        let model = AppModel.preview(now: now)
        model.showingSettings = true
        model.connections.show(statuses: PreviewData.storeConnectedStatuses)
        model.connections.show(access: PreviewData.storeFolderAccess, notices: PreviewData.storeFolderNotices)
        try render(FolderAccessSettings().environment(\.edition, store).controlSize(.small).font(.system(size: 12.5))
                       .padding(12).frame(width: 448),
                   model: model, appearance: looks, surface: popover, to: file("settings-folders"))
        model.connections.show(statuses: PreviewData.storeSetupStatuses, notices: PreviewData.storeSetupNotices)
        model.connections.show(access: PreviewData.storeSetupAccess, problems: PreviewData.storeSetupProblems)
        try render(AgentSettings().environment(\.edition, store).controlSize(.small).font(.system(size: 12.5))
                       .padding(12).frame(width: 448),
                   model: model, appearance: looks, surface: popover, to: file("settings-agents"))
        try render(VStack(spacing: 0) { PanelHeader(); SettingsView() }.environment(\.edition, store)
                       .frame(width: 448, height: 3_000),
                   model: model, appearance: looks, surface: popover, to: file("panel-settings-full"))
        model.connections.show(statuses: PreviewData.storeConnectedStatuses, notices: PreviewData.storeConnectedNotices)
        model.connections.show(access: PreviewData.storeConnectedAccess, claudeHooksTwice: true)
        try render(AgentSettings().environment(\.edition, store).controlSize(.small).font(.system(size: 12.5))
                       .padding(12).frame(width: 448),
                   model: model, appearance: looks, surface: popover, to: file("settings-agents-connected"))
        var linked = PreviewData.settings
        linked.iCloudLink = true
        model.showPreview(settings: linked)
        model.iCloudLink.show(available: true, status: .running, lastSync: now - 12)
        try render(PhoneSettings().environment(\.edition, store).toggleStyle(.switch).controlSize(.small)
                       .font(.system(size: 12.5)).padding(12).frame(width: 448),
                   model: model, appearance: looks, surface: popover, to: file("settings-iphone-on"))

        let sample = AppModel.samplePreview(now: now)
        try render(PanelView().environment(\.edition, store), model: sample, appearance: looks, surface: popover,
                   to: file("panel-sample-data"))
        try render(DashboardView(plainSidebar: true).environment(\.edition, store).frame(width: 1180, height: 760),
                   model: sample, appearance: looks, to: file("dashboard-sample-data"))
        var resumable = PreviewData.history(now: now)
        resumable.selectedSession = resumable.sessions.sessions.first { summary in
            summary.cwd != nil && sample.session(summary.key).map { $0.state == .ended } ?? true
        }
        sample.history.show(resumable, page: .sessions)
        try render(DashboardView(plainSidebar: true).environment(\.edition, store).frame(width: 1180, height: 1_000),
                   model: sample, appearance: looks, to: file("dashboard-session-resume"))
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

#if Sparkle
private struct MenuBarMarks: View {
    private static let states: [(hollowHub: Bool, badged: Bool, count: String)] = [
        (true, false, ""), (true, true, ""), (false, true, ""), (false, true, "2"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            row(scale: 1, spacing: 18)
            row(scale: 4, spacing: 36)
        }
        .padding(16)
    }

    private func row(scale: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(Array(Self.states.enumerated()), id: \.offset) { _, state in
                HStack(spacing: 4 * scale) {
                    let size = HoplyMark.statusBarSize(badged: state.badged)
                    StatusBarMark(hollowHub: state.hollowHub, badged: state.badged)
                        .fill(.primary)
                        .frame(width: size.width * scale, height: size.height * scale)
                    if !state.count.isEmpty {
                        Text(state.count).font(.system(size: 13 * scale))
                    }
                }
            }
        }
    }
}
#endif
