import AgentKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AppSettings()
    @State private var portText = ""
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
