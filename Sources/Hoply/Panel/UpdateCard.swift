import AgentKit
import SwiftUI

struct UpdateCard: View {
    @Environment(AppModel.self) private var model
    let update: PendingUpdate

    var body: some View {
        let ready = update.stage == .ready
        Card(tint: .accentColor) {
            HStack(spacing: 10) {
                IconTile(symbol: ready ? "arrow.down.circle.fill" : "arrow.down.circle", tint: .accentColor, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ready ? "Hoply \(update.version) is ready" : "Hoply \(update.version) is available")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if ready {
                            Text("Installs on quit ·")
                                .foregroundStyle(.secondary)
                        }
                        Link("What's new", destination: Updates.changelog)
                            .foregroundStyle(Color.accentColor)
                            .help(Updates.changelog.absoluteString)
                    }
                    .font(.system(size: 12))
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Later") { model.updates.later() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Hide this card for an hour. The dot on the menu bar icon stays until the update is installed.")
                Button(ready ? "Restart to Update" : "Update") { model.updates.update() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!model.updates.canUpdate)
                    .help(ready ? "Quit Hoply, install \(update.version) and open it again"
                                : "Show what's new in \(update.version) and install it")
            }
        }
    }
}
