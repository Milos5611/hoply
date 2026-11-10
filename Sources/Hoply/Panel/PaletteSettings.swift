import AgentKit
import SwiftUI

struct PaletteSettings: View {
    @Environment(AppModel.self) private var model
    @State private var recorder = HotKeyRecorder()

    var body: some View {
        let enabled = model.settings.paletteEnabled
        let combo = model.settings.paletteHotKey
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Command palette")
                SwitchRow("Command palette and global shortcut", isOn: Binding(get: { model.settings.paletteEnabled },
                                                                              set: { model.setPaletteEnabled($0) }))
                Group {
                    LabeledRow("Shortcut") {
                        Button(recorder.isRecording ? "Press a shortcut…" : combo.displayString) {
                            if recorder.isRecording {
                                endRecording()
                            } else {
                                beginRecording()
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Click, then press the new shortcut")
                        if recorder.isRecording {
                            Text("Esc cancels")
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if combo != .controlOptionSpace, !recorder.isRecording {
                            Button("Use \(HotKeyCombo.controlOptionSpace.displayString)") {
                                model.setPaletteHotKey(.controlOptionSpace)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    if let rejection = recorder.rejection {
                        Text(rejection)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let status = Self.status(model.hotKey)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 7, height: 7)
                        Text(status.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!enabled)
                Hint("Searches sessions, projects, dev servers, Dashboard pages and actions from any app. These settings apply at once, without Save. If pressing the shortcut does nothing, macOS or another app owns it: record another one.")
            }
        }
        .onDisappear { endRecording() }
    }

    private func beginRecording() {
        model.hotKey.setSuspended(true)
        recorder.start { combo in
            model.hotKey.setSuspended(false)
            model.setPaletteHotKey(combo)
        }
    }

    private func endRecording() {
        recorder.stop()
        model.hotKey.setSuspended(false)
    }

    static func status(_ hotKey: HotKey) -> (text: String, color: Color) {
        switch hotKey.status {
        case .off:
            return ("Off", .secondary)
        case .failed(let combo, let reason):
            return ("Could not register \(combo.displayString): \(reason)", .red)
        case .registered(let combo):
            guard let fired = hotKey.lastFired else {
                return ("Registered · not pressed yet. Press \(combo.displayString) to test it.", .orange)
            }
            return ("Working · last pressed \(Format.clock(fired))", .green)
        }
    }
}
