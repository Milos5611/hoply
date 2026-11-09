import AgentKit
import SwiftUI

struct LocalModelWidget: View {
    @Environment(AppModel.self) private var model

    private let tint = SourceBadge.color(for: .qwenCode)

    var body: some View {
        if model.settings.vllmBaseURL.isEmpty {
            WidgetTile(title: "Local model", symbol: "cpu", tint: tint, footer: "No server set") {
                Button("Add server") { model.showingSettings = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else if let status = model.vllm, model.vllmOnline {
            WidgetTile(title: "KV cache", symbol: "cpu", tint: tint,
                       footer: "\(status.snapshot.running) running · \(shortModel(status.snapshot))") {
                HStack(spacing: 10) {
                    RingGauge(fraction: status.snapshot.kvCacheUsage ?? 0, tint: .orange) {
                        Text(status.snapshot.kvCacheUsage.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                    .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Queued")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Text("\(status.snapshot.waiting)")
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    }
                }
            }
        } else {
            WidgetTile(title: "Local model", symbol: "cpu", tint: tint,
                       footer: model.vllmError ?? "Connecting…", footerColor: model.vllmError == nil ? .secondary : .red) {
                RingGauge(fraction: 0, tint: .orange) { EmptyView() }
                    .frame(width: 54, height: 54)
            }
        }
    }

    private func shortModel(_ snapshot: VLLMSnapshot) -> String {
        guard let name = snapshot.model else { return snapshot.engine }
        return name.split(separator: "/").last.map(String.init) ?? name
    }
}
