import AgentKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AppSettings()
    @State private var portText = ""
    @State private var patternsText = ""
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
                                claudeConfigDir: $draft.claudeConfigDir)

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Behaviour")
                        SwitchRow("Notify when an agent needs me", isOn: $draft.notificationsEnabled)
                        SwitchRow("Show Claude plan limits", isOn: $draft.claudeLimitsEnabled)
                        if model.isBundledApp {
                            SwitchRow("Launch at login", isOn: Binding(
                                get: { model.launchAtLogin },
                                set: { model.setLaunchAtLogin($0) }
                            ))
                        } else {
                            Hint("Notifications and launch at login work in the bundled app (scripts/install.sh), not with swift run.")
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
                        .help("Re-read every Claude Code transcript. History is never deleted.")
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
                Hint("Usage comes from Claude Code's transcripts. Models whose name contains a local pattern cost $0 and are priced as the reference model to show their API-equivalent. Reindex re-reads every transcript without deleting history.")
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

    private func statusColor(_ history: History) -> Color {
        switch history.status {
        case .off, .opening: return .secondary
        case .unavailable: return .red
        case .ready: return history.progress.isBackfilling ? .orange : .green
        }
    }
}
