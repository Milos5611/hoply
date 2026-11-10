import AgentKit
import AppKit
import SwiftUI

/// `Hoply --snapshot <dir>` renders the panel and the Dashboard pages with `PreviewData` in light and dark
/// mode to PNGs, so UI work can be checked without Screen Recording permission. Glass and vibrancy are
/// composited by the window server and don't appear; the window background stands in for them.
enum Snapshot {
    static func render(to directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let now = Date()
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let model = AppModel.preview(now: now)
                let looks = NSAppearance(named: appearance)
                try render(PanelView(), model: model, appearance: looks,
                           to: directory.appendingPathComponent("panel-\(name).png"))

                var backfilling = PreviewData.history(now: now)
                backfilling.progress = PreviewData.backfilling
                model.history.show(backfilling)
                try render(VStack(spacing: 0) { PanelHeader(); PanelSections().padding(.horizontal, 12); PanelFooter() }
                               .frame(width: 448),
                           model: model, appearance: looks,
                           to: directory.appendingPathComponent("panel-full-\(name).png"))
                model.showingSettings = true
                try render(PanelView(), model: model, appearance: looks,
                           to: directory.appendingPathComponent("panel-settings-\(name).png"))
                try render(VStack(spacing: 0) { PanelHeader(); SettingsView() }.frame(width: 448, height: 1_300),
                           model: model, appearance: looks,
                           to: directory.appendingPathComponent("panel-settings-full-\(name).png"))

                for page in DashboardPage.allCases {
                    var preview = PreviewData.history(now: now)
                    if page == .overview { preview.progress = PreviewData.backfilling }
                    model.history.show(preview, page: page)
                    let height: CGFloat = switch page {
                    case .projects: 880
                    case .limits: 1_200
                    case .localModel: 1_320
                    default: 760
                    }
                    try render(DashboardView(plainSidebar: true).frame(width: 1180, height: height),
                               model: model, appearance: looks,
                               to: directory.appendingPathComponent("dashboard-\(page.rawValue)-\(name).png"))
                }
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
                model.showPreview(vllm: PreviewData.vllm(now: now), error: "Offline", lastSeen: lastSeen)
                model.history.show(offline, page: .localModel)
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 1_320), model: model,
                           appearance: looks, to: directory.appendingPathComponent("dashboard-local-model-offline-\(name).png"))

                var noServer = PreviewData.settings
                noServer.vllmBaseURL = ""
                var unset = PreviewData.history(now: now)
                unset.localModel?.generation = []
                unset.localModel?.kvCache = []
                let unobserved = (unset.localModel?.tokenDays ?? []).map {
                    ModelTokenDay(day: $0.day, generated: 0, prompt: 0, observed: false)
                }
                unset.localModel?.tokenDays = unobserved
                model.showPreview(settings: noServer)
                model.showPreview(vllm: nil, error: nil, lastSeen: nil)
                model.history.show(unset, page: .localModel)
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 760), model: model,
                           appearance: looks, to: directory.appendingPathComponent("dashboard-local-model-empty-\(name).png"))
                model.showPreview(settings: PreviewData.settings)
                model.showPreview(vllm: PreviewData.vllm(now: now), error: nil, lastSeen: now)

                model.history.showProjectDetail(PreviewData.history(now: now))
                try render(DashboardView(plainSidebar: true).frame(width: 1180, height: 1260), model: model, appearance: looks,
                           to: directory.appendingPathComponent("dashboard-project-detail-\(name).png"))
            }
            print(directory.path)
        } catch {
            FileHandle.standardError.write(Data("Snapshot failed: \(error)\n".utf8))
        }
    }

    private static func render(_ view: some View, model: AppModel, appearance: NSAppearance?, to file: URL) throws {
        let host = NSHostingView(rootView: view
            .environment(model)
            .background(Color(nsColor: .windowBackgroundColor)))
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
