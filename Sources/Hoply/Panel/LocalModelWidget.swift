import AgentKit
import SwiftUI

struct LocalModelWidget: View {
    @Environment(AppModel.self) private var model

    private let tint = SourceBadge.color(for: .qwenCode)

    var body: some View {
        let servers = model.settings.modelServers
        let active = servers.filter(\.isActive)
        if servers.isEmpty {
            WidgetTile(title: "Local model", symbol: "cpu", tint: tint, footer: "No server set") {
                Button("Add server") { model.beginAddingModelServer() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            Button { model.openDashboard(.localModel) } label: {
                if active.count > 1 {
                    several(active)
                } else if let server = active.first {
                    single(server)
                } else {
                    WidgetTile(title: "Local model", symbol: "cpu", tint: tint,
                               footer: servers.count == 1 ? "Server is off" : "\(servers.count) servers off") {
                        Image(systemName: ModelServerHealth.paused.symbol)
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(help(servers))
        }
    }

    private func help(_ servers: [ModelServer]) -> String {
        let lines = servers.map { server in
            ModelServerText.summary(server, model.modelServers.state(of: server.id),
                                    health: model.modelServers.health(of: server))
        }
        return (lines + ["Open Local model in the Dashboard"]).joined(separator: "\n")
    }

    @ViewBuilder
    private func single(_ server: ModelServer) -> some View {
        let state = model.modelServers.state(of: server.id)
        let health = model.modelServers.health(of: server)
        if let status = state?.online {
            let snapshot = status.snapshot
            if let usage = snapshot.metrics.kvCacheUsage {
                WidgetTile(title: "KV cache", symbol: "cpu", tint: tint, footer: footer(status)) {
                    HStack(spacing: 10) {
                        RingGauge(fraction: usage, tint: .orange) {
                            Text("\(Format.whole(usage * 100))%")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        }
                        .frame(width: 54, height: 54)
                        if let queued = snapshot.metrics.waiting ?? snapshot.metrics.running {
                            figure(snapshot.metrics.waiting != nil ? "Queued" : "Running", "\(queued)")
                        }
                    }
                }
            } else {
                WidgetTile(title: server.displayName, symbol: "cpu", tint: tint, footer: footer(status)) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let main = ModelServerText.figure(status) {
                            figure(main.unit.capitalized, main.value)
                        }
                        if let memory = snapshot.memoryBytes {
                            Text("\(ModelServerText.memory(memory)) in memory")
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        } else {
            WidgetTile(title: server.displayName, symbol: "cpu", tint: tint, footer: health.detail,
                       footerColor: health.color) {
                Image(systemName: health.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(health == .connecting ? AnyShapeStyle(.tertiary) : AnyShapeStyle(health.color))
            }
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
        }
    }

    private func footer(_ status: ModelServerStatus) -> String {
        let snapshot = status.snapshot
        let name = snapshot.primaryModel.map(Format.servedModel) ?? snapshot.engine.displayName
        guard let running = snapshot.metrics.running else { return name }
        return "\(running) running · \(name)"
    }

    private func several(_ servers: [ModelServer]) -> some View {
        let live = servers.count { model.modelServers.health(of: $0) == .live }
        let shown = servers.prefix(servers.count > 3 ? 2 : 3)
        return WidgetTile(title: "Model servers", symbol: "cpu", tint: tint,
                          footer: "\(live) of \(servers.count) live",
                          footerColor: live == servers.count ? .secondary : .orange) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shown) { server in
                    row(server)
                }
                if servers.count > shown.count {
                    Text("+\(servers.count - shown.count) more")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ server: ModelServer) -> some View {
        let health = model.modelServers.health(of: server)
        let figure = model.modelServers.state(of: server.id)?.online.flatMap(ModelServerText.figure)
        return HStack(spacing: 5) {
            ModelServerDot(health: health, size: 6)
            Text(server.displayName)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            Text(figure.map { $0.unit == "tok/s" ? "\($0.value) t/s" : "\($0.value) \($0.unit)" } ?? health.label)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(health == .live ? Color.secondary : health.color)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
