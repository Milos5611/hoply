import SwiftUI

struct PanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader()
            Group {
                if model.showingSettings {
                    SettingsView()
                } else {
                    PanelContent()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            PanelFooter()
        }
        .frame(width: 448, height: 600)
    }
}

struct PanelHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Hoply")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            HeaderIconButton(symbol: model.settings.notificationsEnabled ? "bell" : "bell.slash",
                             help: model.settings.notificationsEnabled ? "Pause notifications" : "Resume notifications") {
                model.toggleNotifications()
            }
            HeaderIconButton(symbol: model.showingSettings ? "xmark" : "gearshape",
                             help: model.showingSettings ? "Close settings" : "Settings") {
                model.showingSettings.toggle()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

struct HeaderIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .help(help)
    }
}

struct PanelFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                model.quit()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Quit Hoply")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
