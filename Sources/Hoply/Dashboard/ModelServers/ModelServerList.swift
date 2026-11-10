import AgentKit
import SwiftUI

struct ModelServerList: View {
    @Environment(AppModel.self) private var model
    var opensPage = false
    @State private var removing: String?

    var body: some View {
        let servers = model.settings.modelServers
        VStack(alignment: .leading, spacing: 10) {
            if servers.isEmpty {
                Hint("No model server yet. Add Ollama, LM Studio, llama.cpp, vLLM or any OpenAI-compatible server, on this Mac or remote.")
            }
            ForEach(servers) { server in
                if removing == server.id {
                    confirmRemoval(server)
                } else {
                    row(server)
                }
            }
            ModelServerActions()
        }
        .onChange(of: servers.map(\.id)) { removing = nil }
    }

    private func row(_ server: ModelServer) -> some View {
        let state = model.modelServers.state(of: server.id)
        let health = model.modelServers.health(of: server)
        return HStack(spacing: 8) {
            ModelServerDot(health: health)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text([server.host, ModelServerText.engine(server, state), health.detail].filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if server.enabled, let error = state?.error?.errorDescription {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(health.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .help(server.baseURL)
            Spacer(minLength: 8)
            if opensPage {
                Button { model.showLocalModel(server: server.id) } label: { Image(systemName: "chart.xyaxis.line") }
                    .buttonStyle(.borderless)
                    .help("Show \(server.displayName) on the Local model page")
            }
            Button { model.beginEditingModelServer(server.id) } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .help("Edit \(server.displayName)")
            Button { removing = server.id } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove \(server.displayName)")
            Toggle("Watch \(server.displayName)", isOn: Binding(get: { server.enabled },
                                                                  set: { model.setModelServerEnabled(server.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(server.enabled ? "Stop polling this server" : "Poll this server again")
        }
    }

    private func confirmRemoval(_ server: ModelServer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .foregroundStyle(.red)
                .frame(width: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text("Remove \(server.displayName)?")
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("Its sign-in details leave the Keychain. Recorded history stays in the ledger.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Cancel") { removing = nil }
                .buttonStyle(.bordered)
            Button("Remove") {
                removing = nil
                model.removeModelServer(server.id)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }
}

struct ModelServerActions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.modelServers
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Add server…") { model.beginAddingModelServer() }
                    .buttonStyle(.bordered)
                Button("Find servers on this Mac") { monitor.discover() }
                    .buttonStyle(.bordered)
                    .disabled(monitor.discovery == .searching)
                    .help("Looks once at the usual ports on localhost: Ollama, LM Studio, llama.cpp, vLLM and others")
                if monitor.discovery == .searching {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            if case .found(let candidates) = monitor.discovery {
                found(candidates)
            }
        }
    }

    @ViewBuilder
    private func found(_ candidates: [ModelServerCandidate]) -> some View {
        let configured = Set(model.settings.modelServers.compactMap { $0.endpoint?.baseURL })
        let fresh = candidates.filter { candidate in
            candidate.server.endpoint.map { !configured.contains($0.baseURL) } ?? false
        }
        if candidates.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Hint("No model server answered on localhost (ports \(ports)). If yours uses another port or runs on another machine, add it with its URL.")
                Spacer(minLength: 4)
                Button("Dismiss") { model.modelServers.clearDiscovery() }
                    .buttonStyle(.borderless)
            }
        } else {
            ForEach(fresh) { candidate in
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(candidate.server.displayName)
                            .fontWeight(.medium)
                        Text(detail(candidate))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    Button("Add") { model.addModelServer(candidate.server) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var ports: String {
        ModelServerDiscovery.wellKnownPorts.map { String($0.port) }.joined(separator: ", ")
    }

    private func detail(_ candidate: ModelServerCandidate) -> String {
        var parts = [candidate.server.host]
        if let version = candidate.probe.status?.snapshot.version { parts.append("version \(version)") }
        let models = candidate.probe.models
        if !models.isEmpty {
            let names = models.prefix(2).map { Format.servedModel($0.id) }.joined(separator: ", ")
            parts.append(models.count > 2 ? "\(names) +\(models.count - 2)" : names)
        }
        return parts.joined(separator: " · ")
    }
}
