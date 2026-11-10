import AgentKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    // Every change goes straight to the current settings, so edits made elsewhere (the header bell, a card's
    // mute tile, Limits "Connect") are never overwritten by a stale copy.
    private var live: Binding<AppSettings> {
        Binding(get: { model.settings }, set: { model.apply($0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                AgentSettings()

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Listener")
                        LabeledRow("Port") {
                            CommitField("4318", value: String(model.settings.port)) { text in
                                if let port = Int(text.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(port) {
                                    model.update { $0.port = port }
                                }
                                return String(model.settings.port)
                            }
                            .frame(width: 90)
                            Spacer(minLength: 0)
                        }
                        Hint("Agents send hooks and OpenTelemetry to http://127.0.0.1:<port>, 4318 by default. After a port change, connected agents ask for Update under Agents.")
                    }
                }

                NotificationSettings(settings: live)

                ModelServerSettings()

                HistorySettings()

                PricingSettings(aliases: live.priceAliases)

                CopilotPlanSettings()

                PaletteSettings()

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Behaviour")
                        SwitchRow("Show Claude plan limits", isOn: live.claudeLimitsEnabled)
                        if !model.editors.isEmpty {
                            LabeledRow("Editor") {
                                Picker("Editor", selection: Binding(get: { model.defaultEditor?.id ?? "" },
                                                                    set: { model.setDefaultEditor($0) })) {
                                    ForEach(model.editors) { Text($0.name).tag($0.id) }
                                }
                                .labelsHidden()
                                .fixedSize()
                                Spacer(minLength: 0)
                            }
                            .help("Used by Open in editor on project cards and in the Dashboard.")
                        }
                        if model.isBundledApp {
                            SwitchRow("Launch at login", isOn: Binding(
                                get: { model.launchAtLogin },
                                set: { model.setLaunchAtLogin($0) }
                            ))
                        } else {
                            Hint("Launch at login works in the bundled app (scripts/install.sh), not with swift run.")
                        }
                    }
                }

                if let note = model.lastNote {
                    Hint("Last listener message: \(note)")
                        .padding(.horizontal, 4)
                }

                Hint("Changes are saved as you make them. A text field saves when you press Return or leave it.")
                    .padding(.horizontal, 4)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12.5))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .onAppear {
            model.connections.refresh()
            model.refreshLaunchAtLogin()
            model.refreshEditors()
            model.history.loadPricing()
        }
    }
}

// Applies on Return, on leaving the field, and when Settings or the panel closes; never per keystroke,
// because a half-typed port or folder would restart the listener or reopen the ledger.
struct CommitField: View {
    let placeholder: String
    let value: String
    let commit: (String) -> String

    @State private var text = ""
    @FocusState private var focused: Bool

    init(_ placeholder: String, value: String, commit: @escaping (String) -> String) {
        self.placeholder = placeholder
        self.value = value
        self.commit = commit
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .overlay(alignment: .trailing) {
                if text != value {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 6)
                        .tooltip("Press Return to save")
                }
            }
            .onSubmit(save)
            .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onAppear { text = value }
            .onDisappear(perform: save)
            .onReceive(NotificationCenter.default.publisher(for: NSPopover.willCloseNotification)) { _ in save() }
    }

    private func save() {
        guard text != value else { return }
        text = commit(text)
    }
}

struct SwitchRow: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Toggle(label, isOn: $isOn)
                .labelsHidden()
        }
    }
}

struct HistorySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("History")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(statusColor(history))
                        .frame(width: 7, height: 7)
                    Text(statusText(history))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Reindex") { model.history.reindex() }
                        .buttonStyle(.bordered)
                        .disabled(!history.isReady || history.progress.isBackfilling)
                        .help("Re-read every Claude Code transcript and Copilot CLI's session store. History is never deleted.")
                }
                if history.progress.isBackfilling {
                    ProgressView(value: history.progress.fraction)
                        .progressViewStyle(.linear)
                }
                if let error = history.progress.lastError ?? history.note {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if history.isReady {
                    let copilot = copilotStatus(history.progress.copilot)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(copilot.color)
                            .frame(width: 7, height: 7)
                        Text(copilot.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help(copilot.detail ?? "Copilot CLI's session-store.db, read every 10 seconds")
                }
                LabeledRow("Local models") {
                    CommitField("qwen, llama", value: model.settings.localModelPatterns.joined(separator: ", ")) { text in
                        let patterns = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        model.update { $0.localModelPatterns = patterns }
                        return model.settings.localModelPatterns.joined(separator: ", ")
                    }
                }
                LabeledRow("Priced as") {
                    CommitField(PricingTable.defaultReferenceModel, value: model.settings.referenceModel) { text in
                        let reference = text.trimmingCharacters(in: .whitespaces)
                        model.update { $0.referenceModel = reference.isEmpty ? PricingTable.defaultReferenceModel : reference }
                        return model.settings.referenceModel
                    }
                }
                LabeledRow("Claude dir") {
                    CommitField("~/.claude", value: model.settings.claudeConfigDir) { text in
                        model.update { $0.claudeConfigDir = text.trimmingCharacters(in: .whitespaces) }
                        return model.settings.claudeConfigDir
                    }
                }
                LabeledRow("Copilot dir") {
                    CommitField("~/.copilot", value: model.settings.copilotHome) { text in
                        model.update { $0.copilotHome = text.trimmingCharacters(in: .whitespaces) }
                        return model.settings.copilotHome
                    }
                }
                Hint("Usage comes from Claude Code's transcripts, Copilot CLI's session store, and the OpenTelemetry of Copilot IDE and Qwen Code. Models whose name contains a local pattern cost $0 and are priced as the reference model to show their API-equivalent; =name matches one model exactly, which is what \"Treat as local\" on the Local model page adds. Reindex re-reads the transcripts and the Copilot store without deleting history; sessions indexed by an earlier version get their subagent names that way.")
            }
        }
    }

    private func statusText(_ history: History) -> String {
        switch history.status {
        case .off, .opening:
            return "Opening the usage ledger…"
        case .unavailable(let reason):
            return reason
        case .ready:
            let progress = history.progress
            if progress.isBackfilling {
                return "Indexing \(progress.filesDone) of \(progress.filesTotal) transcripts · \(Format.percent(progress.fraction))"
            }
            return progress.filesTotal > 0 ? "Up to date · indexed \(progress.filesTotal) transcripts" : "Up to date"
        }
    }

    private func copilotStatus(_ status: CopilotStoreStatus) -> (text: String, color: Color, detail: String?) {
        switch status {
        case .idle: return ("Copilot CLI: not read yet", .secondary, nil)
        case .notFound: return ("Copilot CLI: no session store found", .secondary, nil)
        case .ready: return ("Copilot CLI: up to date", .green, nil)
        case .unsupported(let detail): return ("Copilot CLI: unsupported schema, not read", .orange, detail)
        case .failed(let message): return ("Copilot CLI: last read failed", .red, message)
        }
    }

    private func statusColor(_ history: History) -> Color {
        switch history.status {
        case .off, .opening: return .secondary
        case .unavailable: return .red
        case .ready: return history.progress.isBackfilling ? .orange : .green
        }
    }
}

struct PricingSettings: View {
    @Environment(AppModel.self) private var model
    @Binding var aliases: [String: String]

    var body: some View {
        let history = model.history
        let unpriced = history.unpricedModels.filter { !$0.model.isEmpty }
        let listed = Set(unpriced.map { Self.key($0.model) })
        let aliased = aliases.keys.filter { !listed.contains($0) }.sorted()
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Pricing")
                if unpriced.isEmpty, aliased.isEmpty {
                    Hint("Every model in the ledger has a price. A model Hoply has no price for is listed here, so you can price it as a similar one.")
                } else {
                    ForEach(unpriced) { entry in
                        row(entry.model, detail: "\(Format.count(entry.calls)) \(entry.calls == 1 ? "call" : "calls") · \(Format.tokens(entry.tokens.total)) tokens unpriced")
                    }
                    ForEach(aliased, id: \.self) { name in
                        row(name, detail: nil)
                    }
                    Hint("Price as charges a model at another model's list price and re-prices its history as soon as you pick one. Spend stays \"unpriced\" until then, never $0.")
                }
            }
        }
    }

    private func row(_ name: String, detail: String?) -> some View {
        let key = Self.key(name)
        let target = aliases[key] ?? ""
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail ?? "Priced as \(Format.model(target))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(detail != nil && target.isEmpty ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            .help(name)
            Spacer(minLength: 8)
            Picker("Price as", selection: Binding(get: { target }, set: { aliases[key] = $0.isEmpty ? nil : $0 })) {
                Text("Price as…").tag("")
                ForEach(choices(including: target), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 170)
        }
    }

    private func choices(including target: String) -> [String] {
        let priced = model.history.pricedModels
        return target.isEmpty || priced.contains(target) ? priced : priced + [target]
    }

    private static func key(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @Binding var settings: AppSettings

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Notifications")
                SwitchRow("Notify when an agent needs me", isOn: $settings.notificationsEnabled)
                Group {
                    SwitchRow("Claude limit alerts at 80% and 95%", isOn: $settings.limitAlertsEnabled)
                    SwitchRow("Local model offline for 2 minutes", isOn: $settings.localModelAlertsEnabled)
                    SwitchRow("Quiet hours", isOn: $settings.quietHoursEnabled)
                    if settings.quietHoursEnabled {
                        HStack(spacing: 8) {
                            Text("Silent from")
                                .foregroundStyle(.secondary)
                            TimeOfDayField(minutes: $settings.quietHoursStart)
                            Text("to")
                                .foregroundStyle(.secondary)
                            TimeOfDayField(minutes: $settings.quietHoursEnd)
                            Spacer()
                        }
                    }
                }
                .disabled(!settings.notificationsEnabled)
                Divider()
                SwitchRow("Approve Claude Code prompts from Hoply", isOn: $settings.approveFromHoply)
                Hint("Adds Allow and Deny for Claude Code's permission prompts to the panel and its notifications, for that one request. The terminal prompt stays up; whichever answers first wins. Needs Claude Code connected under Agents; press Update there if it asks.")
                Divider()
                Text("Muted projects")
                if settings.mutedProjectRoots.isEmpty {
                    Hint("None. Mute a project with the bell button on its card; muting covers that project only, not the repos inside it.")
                } else {
                    ForEach(settings.mutedProjectRoots, id: \.self) { root in
                        HStack(spacing: 8) {
                            Image(systemName: "bell.slash")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(title(root))
                                    .lineLimit(1)
                                Text(Format.path(root))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Button("Unmute") { settings.mutedProjectRoots.removeAll { $0 == root } }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                if !model.isBundledApp {
                    Hint("Notifications only work in the bundled app (scripts/install.sh), not with swift run.")
                }
            }
        }
    }

    private func title(_ root: String) -> String {
        model.projectsByCwd.values.first { $0.root == root }?.title ?? (root as NSString).lastPathComponent
    }
}

struct TimeOfDayField: View {
    @Binding var minutes: Int

    var body: some View {
        DatePicker("Time", selection: Binding(get: { Format.date(minutesAfterMidnight: minutes) }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .datePickerStyle(.field)
        .fixedSize()
    }
}

struct CopilotPlanSettings: View {
    @Environment(AppModel.self) private var model

    private static let plans: [(name: String, allowance: Int)] = [
        ("Free", 50), ("Pro", 300), ("Pro+", 1_500), ("Business", 300), ("Enterprise", 1_000),
    ]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Copilot plan")
                LabeledRow("Allowance") {
                    CommitField("300", value: String(model.settings.copilotMonthlyAllowance)) { text in
                        if let allowance = Int(text.trimmingCharacters(in: .whitespaces)), allowance >= 0 {
                            model.update { $0.copilotMonthlyAllowance = allowance }
                        }
                        return String(model.settings.copilotMonthlyAllowance)
                    }
                    .frame(width: 70)
                    Text("premium requests a month")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Menu("Plan") {
                        ForEach(Self.plans, id: \.name) { plan in
                            Button("\(plan.name) · \(Format.count(plan.allowance))") {
                                model.update { $0.copilotMonthlyAllowance = plan.allowance }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                LabeledRow("Extra cost") {
                    CommitField("0.04", value: String(model.settings.copilotUSDPerPremiumRequest)) { text in
                        let usd = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
                            .replacingOccurrences(of: ",", with: ".")
                        if let usd = Double(usd), usd >= 0, usd.isFinite {
                            model.update { $0.copilotUSDPerPremiumRequest = usd }
                        }
                        return String(model.settings.copilotUSDPerPremiumRequest)
                    }
                    .frame(width: 70)
                    Text("USD per request beyond it")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Hint("Premium requests a month: Free 50, Pro 300, Pro+ 1,500, Business 300, Enterprise 1,000. 0 shows usage without an allowance. The Limits page in the Dashboard counts Copilot CLI against it.")
            }
        }
    }
}
