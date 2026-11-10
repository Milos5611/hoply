import AgentKit
import SwiftUI

extension DevServer {
    var shortName: String { "\(frameworkName) \(portLabel)" }

    var networkHelp: String {
        let open = listeners.filter { $0.reach != .loopback }
        if open.contains(where: { $0.reach == .allInterfaces }) {
            return "Listening on all interfaces: other devices on your network can reach port \(port)"
        }
        let addresses = Set(open.map(\.address)).sorted().joined(separator: ", ")
        return "Listening on \(addresses): reachable from the network"
    }

    var summaryHelp: String {
        var lines = ["Open \(url.absoluteString)", displayName, Format.path(cwd)]
        if isReachableFromNetwork { lines.append(networkHelp) }
        return lines.joined(separator: "\n")
    }
}

struct DevServerMenu: View {
    @Environment(AppModel.self) private var model
    let server: DevServer

    var body: some View {
        Button("Open in Browser") { WorkspaceActions.openInBrowser(server.url) }
        Button("Copy URL") { WorkspaceActions.copy(server.url.absoluteString) }
        Button("Reveal in Finder") { WorkspaceActions.revealInFinder(server.cwd) }
        Divider()
        if let refusal = server.stopRefusal {
            Section(refusal.reason) {
                Button("Stop…") {}
                    .disabled(true)
            }
        } else {
            Button("Stop…") { model.devServers.askStop(server) }
                .disabled(model.devServers.stopState(of: server) == .stopping)
        }
    }
}

struct DevServerPill: View {
    @Environment(AppModel.self) private var model
    let server: DevServer

    var body: some View {
        Button { WorkspaceActions.openInBrowser(server.url) } label: {
            HStack(spacing: 4) {
                if model.devServers.stopState(of: server) == .stopping {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                }
                Text(server.frameworkName)
                    .font(.system(size: 11, weight: .medium))
                Text(server.portLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                if server.isReachableFromNetwork {
                    Image(systemName: "network")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(server.summaryHelp)
        .contextMenu { DevServerMenu(server: server) }
    }
}

struct DevServerStrip: View {
    @Environment(AppModel.self) private var model
    let servers: [DevServer]

    var body: some View {
        let devServers = model.devServers
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(servers) { server in
                    DevServerPill(server: server)
                }
            }
            ForEach(servers) { server in
                switch devServers.stopState(of: server) {
                case .confirming:
                    HStack(spacing: 8) {
                        Text("Stop \(server.shortName)?")
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Cancel") { devServers.cancelStop(server) }
                            .foregroundStyle(.secondary)
                        Button("Stop") { devServers.confirmStop(server) }
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5, weight: .semibold))
                    .help(DevServerStopText.confirmation(server, processes: devServers.processCount(of: server)))
                case .failed(let reason):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(server.shortName): \(reason)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button { devServers.cancelStop(server) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10, weight: .semibold))
                            .help("Dismiss")
                    }
                case .stopping, nil:
                    EmptyView()
                }
            }
        }
    }
}

enum DevServerStopText {
    static func confirmation(_ server: DevServer, processes: Int) -> String {
        let group = processes == 1 ? "its process" : "its \(processes) processes"
        return "Sends SIGTERM to \(group), then force quits what is left after \(DevServers.graceSeconds) s"
    }
}
