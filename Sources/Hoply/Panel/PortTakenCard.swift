import AgentKit
import SwiftUI

struct PortTakenCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.edition) private var edition
    let port: UInt16

    var body: some View {
        Card(tint: .red) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    IconTile(symbol: "exclamationmark.triangle.fill", tint: .red, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Port \(String(port)) is taken")
                            .font(.system(size: 13, weight: .semibold))
                        Text(explanation)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Change Port…") { model.showingSettings = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Settings → Listener")
                    Button("Try Again") { model.restartListener() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Listen on 127.0.0.1:\(String(port)) again, for after you quit the other copy")
                }
            }
        }
    }

    private var explanation: String {
        let other = edition == .appStore ? "most likely Hoply from hoply.dev" : "most likely another copy of Hoply, such as the Mac App Store one"
        return "Another app is listening on 127.0.0.1:\(String(port)), \(other). Your agents report to that app, so this one shows nothing. Quit the other copy and press Try Again, or pick another port under Listener and set your agents up again for it."
    }
}
