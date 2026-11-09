import AgentKit
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
            HeaderIconButton(symbol: "macwindow", help: "Open Dashboard") {
                model.openDashboard()
            }
            HeaderIconButton(symbol: model.settings.notificationsEnabled ? "bell" : "bell.slash", help: bellHelp) {
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

    private var bellHelp: String {
        guard model.settings.notificationsEnabled else { return "Resume notifications" }
        return model.quietHoursNote.map { "Pause notifications · \($0)" } ?? "Pause notifications"
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
            if model.history.progress.isBackfilling {
                BackfillIndicator(progress: model.history.progress)
            }
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

struct BackfillIndicator: View {
    let progress: IngestProgress

    var body: some View {
        HStack(spacing: 5) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.circular)
                .controlSize(.mini)
            Text("Indexing history \(Format.percent(progress.fraction))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("Reading Claude Code transcripts: \(progress.filesDone) of \(progress.filesTotal) files, "
              + "\(Format.bytes(progress.bytesDone)) of \(Format.bytes(progress.bytesTotal))")
    }
}
