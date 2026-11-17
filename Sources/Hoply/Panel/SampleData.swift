import SwiftUI

struct SampleDataBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(tint: .purple, padding: 10) {
            HStack(spacing: 10) {
                IconTile(symbol: "theatermasks.fill", tint: .purple, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sample data")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Made-up sessions, projects and costs that show what Hoply looks like. None of it is yours.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Exit Sample Data") { model.hideSampleData() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Back to your own sessions and history")
            }
        }
    }
}

struct SampleDataOfferCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack(spacing: 10) {
                IconTile(symbol: "sparkles", tint: .purple, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No agent sessions yet")
                        .font(.system(size: 13, weight: .medium))
                    Text("Sessions, usage and costs show up here once Claude Code, Codex or Copilot runs with Hoply connected. Until then, look around with made-up data.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Show Sample Data") { model.showSampleData() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Fills the panel and the Dashboard with made-up data until you exit or quit; nothing is saved")
            }
        }
    }
}
