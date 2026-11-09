import AgentKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AppSettings()
    @State private var portText = ""
    @State private var patternsText = ""
    @State private var allowanceText = ""
    @State private var usdText = ""
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Listener")
                        LabeledRow("Port") {
                            TextField("4318", text: $portText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                        }
                        Hint("Agents send hooks and OpenTelemetry to http://127.0.0.1:<port>. The setup scripts default to 4318.")
                    }
                }

                NotificationSettings(draft: $draft)

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Local model")
                        LabeledRow("Name") {
                            TextField("Local model", text: $draft.vllmName)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledRow("Server URL") {
                            TextField("http://<server-ip>:8000", text: $draft.vllmBaseURL)
                                .textFieldStyle(.roundedBorder)
                        }
                        Hint("The base URL of the model server (vLLM or tensorfold), e.g. http://192.168.1.20:8000. Hoply reads <url>/metrics every 5 seconds.")
                    }
                }

                HistorySettings(patternsText: $patternsText, referenceModel: $draft.referenceModel,
                                claudeConfigDir: $draft.claudeConfigDir, copilotHome: $draft.copilotHome)

                CopilotPlanSettings(allowanceText: $allowanceText, usdText: $usdText)

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Behaviour")
                        SwitchRow("Show Claude plan limits", isOn: $draft.claudeLimitsEnabled)
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

                HStack {
                    Spacer()
                    Button("Cancel") { model.showingSettings = false }
                        .buttonStyle(.bordered)
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 2)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12.5))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .onAppear {
            model.refreshLaunchAtLogin()
            guard !loaded else { return }
            draft = model.settings
            portText = String(model.settings.port)
            patternsText = model.settings.localModelPatterns.joined(separator: ", ")
            allowanceText = String(model.settings.copilotMonthlyAllowance)
            usdText = String(model.settings.copilotUSDPerPremiumRequest)
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
        updated.localModelPatterns = patternsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let reference = updated.referenceModel.trimmingCharacters(in: .whitespaces)
        updated.referenceModel = reference.isEmpty ? PricingTable.defaultReferenceModel : reference
        updated.claudeConfigDir = updated.claudeConfigDir.trimmingCharacters(in: .whitespaces)
        updated.copilotHome = updated.copilotHome.trimmingCharacters(in: .whitespaces)
        if let allowance = Int(allowanceText.trimmingCharacters(in: .whitespaces)), allowance >= 0 {
            updated.copilotMonthlyAllowance = allowance
        }
        let usd = usdText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: ".")
        if let usd = Double(usd), usd >= 0, usd.isFinite {
            updated.copilotUSDPerPremiumRequest = usd
        }
        model.apply(updated)
        model.showingSettings = false
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
    @Binding var patternsText: String
    @Binding var referenceModel: String
    @Binding var claudeConfigDir: String
    @Binding var copilotHome: String

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
                    TextField("qwen, llama", text: $patternsText)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledRow("Priced as") {
                    TextField(PricingTable.defaultReferenceModel, text: $referenceModel)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledRow("Claude dir") {
                    TextField("~/.claude", text: $claudeConfigDir)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledRow("Copilot dir") {
                    TextField("~/.copilot", text: $copilotHome)
                        .textFieldStyle(.roundedBorder)
                }
                Hint("Usage comes from Claude Code's transcripts, Copilot CLI's session store, and the OpenTelemetry of Copilot IDE and Qwen Code. Models whose name contains a local pattern cost $0 and are priced as the reference model to show their API-equivalent. Reindex re-reads the transcripts and the Copilot store without deleting history.")
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

struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: AppSettings

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Notifications")
                SwitchRow("Notify when an agent needs me", isOn: $draft.notificationsEnabled)
                Group {
                    SwitchRow("Claude limit alerts at 80% and 95%", isOn: $draft.limitAlertsEnabled)
                    SwitchRow("Local model offline for 2 minutes", isOn: $draft.localModelAlertsEnabled)
                    SwitchRow("Quiet hours", isOn: $draft.quietHoursEnabled)
                    if draft.quietHoursEnabled {
                        HStack(spacing: 8) {
                            Text("Silent from")
                                .foregroundStyle(.secondary)
                            TimeOfDayField(minutes: $draft.quietHoursStart)
                            Text("to")
                                .foregroundStyle(.secondary)
                            TimeOfDayField(minutes: $draft.quietHoursEnd)
                            Spacer()
                        }
                    }
                }
                .disabled(!draft.notificationsEnabled)
                Divider()
                Text("Muted projects")
                if draft.mutedProjectRoots.isEmpty {
                    Hint("None. Mute a project with the bell button on its card; muting covers that project only, not the repos inside it.")
                } else {
                    ForEach(draft.mutedProjectRoots, id: \.self) { root in
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
                            Button("Unmute") { draft.mutedProjectRoots.removeAll { $0 == root } }
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

/// A time of day stored as minutes after midnight.
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
    @Binding var allowanceText: String
    @Binding var usdText: String

    private static let plans: [(name: String, allowance: Int)] = [
        ("Free", 50), ("Pro", 300), ("Pro+", 1_500), ("Business", 300), ("Enterprise", 1_000),
    ]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Copilot plan")
                LabeledRow("Allowance") {
                    TextField("300", text: $allowanceText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("premium requests a month")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Menu("Plan") {
                        ForEach(Self.plans, id: \.name) { plan in
                            Button("\(plan.name) · \(Format.count(plan.allowance))") { allowanceText = String(plan.allowance) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                LabeledRow("Extra cost") {
                    TextField("0.04", text: $usdText)
                        .textFieldStyle(.roundedBorder)
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
