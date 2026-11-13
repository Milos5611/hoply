import AgentKit
import SwiftUI

struct DevServerGroup: Identifiable {
    var id: String
    var name: String
    var path: String
    var project: ProjectRef?
    var servers: [DevServer]

    static func groups(of servers: [DevServer]) -> [DevServerGroup] {
        var groups: [DevServerGroup] = []
        for server in servers {
            if let index = groups.firstIndex(where: { $0.id == server.groupKey }) {
                groups[index].servers.append(server)
            } else {
                groups.append(DevServerGroup(id: server.groupKey, name: server.projectName,
                                             path: server.project?.root ?? server.cwd, project: server.project,
                                             servers: [server]))
            }
        }
        return groups
    }
}

struct DevServersPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let devServers = model.devServers
        let groups = DevServerGroup.groups(of: devServers.servers)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Dev servers", subtitle: subtitle(devServers)) {
                    if devServers.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button { devServers.refresh() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(devServers.isScanning)
                    .tooltip("Scan for listening processes now")
                }
                if let notice = devServers.notice {
                    Card(prominent: true, tint: notice.isError ? .red : .green) {
                        Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill"
                                                                       : "checkmark.circle.fill")
                            .font(.system(size: 12.5))
                            .foregroundStyle(notice.isError ? Color.red : Color.green)
                    }
                }
                if groups.isEmpty {
                    DevServersEmptyCard(scanned: devServers.lastScan != nil,
                                        unavailable: devServers.scan?.snapshot.source == .unavailable)
                } else {
                    ForEach(groups) { group in
                        DevServerGroupCard(group: group)
                    }
                }
            }
            .padding(24)
        }
    }

    private func subtitle(_ devServers: DevServers) -> String {
        guard let last = devServers.lastScan else { return "Local servers started from your project folders" }
        let count = devServers.servers.count
        let running = count == 0 ? "Nothing running" : count == 1 ? "1 server running" : "\(count) servers running"
        return "\(running) · last scan \(Format.clock(last))"
    }
}

private struct DevServersEmptyCard: View {
    let scanned: Bool
    let unavailable: Bool

    var body: some View {
        Card(prominent: true, padding: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "server.rack", tint: .secondary, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text("Processes of yours that listen on a TCP port from a project folder show up here: Next.js, Vite, Uvicorn, Rails, dotnet and the like. Databases and system services are left out.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var title: String {
        if !scanned { return "Looking for dev servers…" }
        return unavailable ? "The process list is unavailable" : "No dev servers running"
    }
}

private struct DevServerGroupCard: View {
    let group: DevServerGroup

    var body: some View {
        Card(prominent: true, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ProjectIcon(kind: group.project?.kind, title: group.name, key: group.path, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(Format.path(group.path))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    CountChip(value: group.servers.count, label: group.servers.count == 1 ? "server" : "servers",
                              tint: .green)
                }
                ForEach(group.servers) { server in
                    DevServerRow(server: server, root: group.project?.root)
                }
            }
        }
    }
}

private struct DevServerRow: View {
    @Environment(AppModel.self) private var model
    let server: DevServer
    let root: String?

    var body: some View {
        let devServers = model.devServers
        let state = devServers.stopState(of: server)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(server.frameworkName)
                            .font(.system(size: 13, weight: .medium))
                        Text(server.portLabel)
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        if server.isReachableFromNetwork {
                            Label("Network", systemImage: "network")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .foregroundStyle(.orange)
                                .background(Capsule().fill(Color.orange.opacity(0.15)))
                                .help(server.networkHelp)
                        }
                    }
                    Text(facts)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Format.path(server.cwd))
                }
                Spacer(minLength: 12)
                if let session = model.session(server.session) {
                    HStack(spacing: 6) {
                        SourceBadge(source: session.key.source, size: 20)
                        Text(session.title ?? session.key.source.displayName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 240, alignment: .trailing)
                    .help(server.sessionMatch == .lineage ? "Started by this session"
                                                          : "This session works in the server's folder")
                }
                trailing(state, devServers: devServers)
            }
            if case .failed(let reason) = state {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                    Button { devServers.cancelStop(server) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10, weight: .semibold))
                        .tooltip("Dismiss")
                }
                .padding(.leading, 42)
            }
        }
        .contextMenu { DevServerMenu(server: server) }
    }

    @ViewBuilder
    private func trailing(_ state: DevServers.StopState?, devServers: DevServers) -> some View {
        switch state {
        case .confirming:
            HStack(spacing: 8) {
                Text("Stop \(server.shortName)?")
                    .font(.system(size: 12, weight: .medium))
                Button("Cancel") { devServers.cancelStop(server) }
                Button("Stop") { devServers.confirmStop(server) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .controlSize(.small)
            .help(DevServerStopText.confirmation(server, processes: devServers.processCount(of: server)))
        case .stopping:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Stopping… force quits after \(DevServers.graceSeconds) s")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .failed, nil:
            HStack(spacing: 6) {
                DevServerAction(symbol: "safari", help: "Open \(server.url.absoluteString)") {
                    WorkspaceActions.openInBrowser(server.url)
                }
                DevServerAction(symbol: "link", help: "Copy the URL") {
                    WorkspaceActions.copy(server.url.absoluteString)
                }
                DevServerAction(symbol: "folder", help: "Show in Finder") {
                    WorkspaceActions.revealInFinder(server.cwd)
                }
                DevServerAction(symbol: "stop.fill", help: server.stopRefusal?.reason ?? "Stop this server…",
                                tint: .red, enabled: server.canStop) {
                    devServers.askStop(server)
                }
            }
        }
    }

    private var facts: String {
        var parts = [server.url.absoluteString]
        if let memory = server.memoryLabel { parts.append(memory) }
        if let root {
            switch SessionPlace(cwd: server.cwd, root: root) {
            case .subfolder(let name), .project(let name): parts.append(name)
            case .worktree(let name): parts.append("worktree \(name)")
            case nil: parts.append("project root")
            }
        }
        return parts.joined(separator: " · ")
    }
}

private struct DevServerAction: View {
    let symbol: String
    let help: String
    var tint: Color = .primary
    var enabled = true
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled && enabled ? tint : Color.secondary.opacity(0.5))
                .frame(width: 30, height: 26)
                .background(shape.fill(Color.primary.opacity(0.05)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        // Outside .disabled, so a refused Stop still shows its reason on hover.
        .disabled(!enabled)
        .tooltip(help)
    }
}
