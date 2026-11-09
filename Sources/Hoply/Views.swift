import AgentKit
import AppKit
import SwiftUI

struct PanelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider()
            Group {
                if model.showingSettings {
                    SettingsView()
                } else {
                    DashboardView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            FooterView()
        }
        .frame(width: 420, height: 580)
    }
}

// MARK: - Header and footer

struct HeaderView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Hoply")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            CountChip(value: model.attentionCount, label: "need you", tint: .orange)
            CountChip(value: model.workingCount, label: "working", tint: .blue)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct CountChip: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        let color: Color = value > 0 ? tint : .secondary
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct FooterView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                model.showingSettings.toggle()
            } label: {
                Image(systemName: model.showingSettings ? "xmark.circle" : "gearshape")
            }
            .buttonStyle(.borderless)
            .help(model.showingSettings ? "Close settings" : "Settings")
            Button("Quit") { model.quit() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var statusText: String {
        switch model.serverStatus {
        case .listening(let port): return "Listening on 127.0.0.1:\(port)"
        case .failed(let message): return message
        case .stopped: return "Listener stopped"
        }
    }

    private var statusColor: Color {
        switch model.serverStatus {
        case .listening: return .green
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Agents")
                if model.sessions.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("No agent sessions yet")
                                .font(.system(size: 12, weight: .medium))
                            Text("Run the setup scripts once, then start Claude Code, Copilot CLI or Qwen Code. Sessions show up here as they report in.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    ForEach(model.sessions) { session in
                        SessionRow(session: session)
                    }
                }

                SectionTitle("Local model")
                    .padding(.top, 8)
                LocalModelCard()

                SectionTitle("Claude plan")
                    .padding(.top, 8)
                ClaudeLimitsCard()
            }
            .padding(12)
        }
    }
}

struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

// MARK: - Sessions

struct SessionRow: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SourceBadge(source: session.key.source)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(detailColor)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                StatePill(state: session.state)
                if session.totalTokens > 0 {
                    Text(usage)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(session.state.needsAttention
                      ? StatePill.color(for: session.state).opacity(0.10)
                      : Color.primary.opacity(0.045))
        )
        .contextMenu {
            if let cwd = session.cwd {
                Button("Reveal in Finder") {
                    _ = NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
                }
                Button("Open in Terminal") {
                    NSWorkspace.shared.open([URL(fileURLWithPath: cwd)],
                                            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                            configuration: NSWorkspace.OpenConfiguration())
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cwd, forType: .string)
                }
                Divider()
            }
            Button("Dismiss") { model.dismiss(session.key) }
        }
    }

    private var title: String {
        session.title ?? session.project ?? session.key.source.displayName
    }

    private var subtitle: String {
        var parts: [String] = []
        if session.title != nil, let project = session.project { parts.append(project) }
        parts.append(session.key.source.displayName)
        if let model = session.model { parts.append(model) }
        parts.append(Format.age(since: session.stateSince))
        return parts.joined(separator: " · ")
    }

    private var detail: String? {
        switch session.state {
        case .needsPermission: return session.lastMessage ?? "Waiting for your approval"
        case .yourTurn: return session.lastMessage
        case .working: return session.lastTool.map { "Last tool: \($0)" }
        case .idle, .ended: return nil
        }
    }

    private var detailColor: Color {
        session.state == .needsPermission ? .red : .secondary
    }

    private var usage: String {
        var text = "\(Format.tokens(session.totalTokens)) tok"
        if session.costUSD > 0 { text += " · \(Format.cost(session.costUSD))" }
        return text
    }
}

struct SourceBadge: View {
    let source: AgentSource

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color))
            .help(source.displayName)
    }

    private var symbol: String {
        switch source {
        case .claudeCode: return "sparkle"
        case .copilotCLI: return "terminal"
        case .copilotIDE: return "curlybraces"
        case .qwenCode: return "cpu"
        }
    }

    private var color: Color {
        switch source {
        case .claudeCode: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .copilotCLI: return Color(red: 0.43, green: 0.33, blue: 0.84)
        case .copilotIDE: return Color(red: 0.30, green: 0.42, blue: 0.86)
        case .qwenCode: return Color(red: 0.20, green: 0.60, blue: 0.55)
        }
    }
}

struct StatePill: View {
    let state: SessionState

    var body: some View {
        let color = Self.color(for: state)
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var label: String {
        switch state {
        case .needsPermission: return "Permission"
        case .yourTurn: return "Your turn"
        case .working: return "Working"
        case .idle: return "Idle"
        case .ended: return "Ended"
        }
    }

    static func color(for state: SessionState) -> Color {
        switch state {
        case .needsPermission: return .red
        case .yourTurn: return .orange
        case .working: return .blue
        case .idle: return .gray
        case .ended: return .secondary
        }
    }
}

// MARK: - Local model

struct LocalModelCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            if model.settings.vllmBaseURL.isEmpty {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("vLLM not connected")
                            .font(.system(size: 12, weight: .medium))
                        Text("Add your server's URL in Settings")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Settings") { model.showingSettings = true }
                        .controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isOnline ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                        Text(model.settings.vllmName.isEmpty ? "vLLM" : model.settings.vllmName)
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.vllm?.snapshot.model ?? "vLLM")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let error = model.vllmError {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                    }
                    if let status = model.vllm, model.vllmError == nil {
                        HStack(spacing: 0) {
                            Metric(value: "\(status.snapshot.running)", label: "running")
                            Metric(value: "\(status.snapshot.waiting)", label: "queued")
                            Metric(value: Format.rate(status.generationTokensPerSecond), label: "gen tok/s")
                            Metric(value: Format.rate(status.promptTokensPerSecond), label: "prompt tok/s")
                        }
                        if let usage = status.snapshot.kvCacheUsage {
                            Meter(label: "KV cache", fraction: usage, caption: "\(Int((usage * 100).rounded()))%")
                        }
                    }
                }
            }
        }
    }

    private var isOnline: Bool {
        model.vllm != nil && model.vllmError == nil
    }
}

struct Metric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Meter: View {
    let label: String
    let fraction: Double
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(caption)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, geometry.size.width * clamped))
                }
            }
            .frame(height: 5)
        }
    }

    private var clamped: Double { min(max(fraction, 0), 1) }

    private var tint: Color {
        if clamped >= 0.9 { return .red }
        if clamped >= 0.7 { return .orange }
        return .accentColor
    }
}

// MARK: - Claude plan limits

struct ClaudeLimitsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            if !model.settings.claudeLimitsEnabled {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("5-hour and weekly limits")
                            .font(.system(size: 12, weight: .medium))
                        Text("Reads Claude Code's login from your Keychain; macOS asks once.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Connect") { model.enableClaudeLimits() }
                        .controlSize(.small)
                }
            } else if let limits = model.claudeLimits {
                VStack(alignment: .leading, spacing: 10) {
                    if let window = limits.fiveHour {
                        Meter(label: "5-hour", fraction: window.utilization / 100, caption: caption(window))
                    }
                    if let window = limits.sevenDay {
                        Meter(label: "Week", fraction: window.utilization / 100, caption: caption(window))
                    }
                    if let window = limits.sevenDayOpus {
                        Meter(label: "Week · Opus", fraction: window.utilization / 100, caption: caption(window))
                    }
                    if let error = model.claudeLimitsError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
            } else {
                Text(model.claudeLimitsError ?? "Loading…")
                    .font(.system(size: 11))
                    .foregroundStyle(model.claudeLimitsError == nil ? Color.secondary : Color.red)
            }
        }
    }

    private func caption(_ window: ClaudeLimits.Window) -> String {
        let percent = "\(Int(window.utilization.rounded()))%"
        let reset = Format.resetTime(window.resetsAt)
        return reset.isEmpty ? percent : "\(percent) · \(reset)"
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State var draft = AppSettings()
    @State var portText = ""
    @State var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Listener")
                LabeledRow("Port") {
                    TextField("4318", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Hint("Agents send hooks and OpenTelemetry to http://127.0.0.1:<port>. The setup scripts default to 4318.")

                SectionTitle("Local model (vLLM)")
                    .padding(.top, 6)
                LabeledRow("Name") {
                    TextField("Local model", text: $draft.vllmName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledRow("Server URL") {
                    TextField("http://<server-ip>:8000", text: $draft.vllmBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
                Hint("The base URL of the vLLM OpenAI server. Hoply reads <url>/metrics every 5 seconds.")

                SectionTitle("Behaviour")
                    .padding(.top, 6)
                Toggle("Notify when an agent needs me", isOn: $draft.notificationsEnabled)
                Toggle("Show Claude plan limits", isOn: $draft.claudeLimitsEnabled)
                if model.isBundledApp {
                    Toggle("Launch at login", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                } else {
                    Hint("Notifications and launch at login work in the bundled app (scripts/install.sh), not with swift run.")
                }

                if let note = model.lastNote {
                    Hint("Last listener message: \(note)")
                }

                HStack {
                    Spacer()
                    Button("Cancel") { model.showingSettings = false }
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 6)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            .padding(14)
        }
        .onAppear {
            guard !loaded else { return }
            draft = model.settings
            portText = String(model.settings.port)
            loaded = true
        }
    }

    private func save() {
        var updated = draft
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        if let port = Int(trimmed), (1024...65535).contains(port) {
            updated.port = port
        }
        updated.vllmBaseURL = updated.vllmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        model.apply(updated)
        model.showingSettings = false
    }
}

struct LabeledRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 80, alignment: .leading)
            content
        }
    }
}

struct Hint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
