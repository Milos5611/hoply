import AgentKit
import SwiftUI

struct CleanupReviewSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cleanup = model.cleanup
        let selected = cleanup.selected
        let kinds = CleanupKind.allCases.filter { kind in selected.contains { $0.kind == kind } }
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Review clean up")
                    .font(.system(size: 17, weight: .bold))
                Text("Each item is checked once more right before it is removed.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(kinds, id: \.self) { kind in
                        group(kind, items: selected.filter { $0.kind == kind })
                    }
                }
            }
            .frame(maxHeight: 380)
            Divider()
            HStack(spacing: 10) {
                Text("\(CleanupSummary.items(selected.count)) · \(Format.bytes(cleanup.selectedBytes))")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Spacer()
                Button("Cancel") { cleanup.isReviewing = false }
                    .keyboardShortcut(.cancelAction)
                Button(CleanupSummary.action(for: selected)) { cleanup.run() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func group(_ kind: CleanupKind, items: [CleanupCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconTile(symbol: kind.symbol, tint: kind.tint, size: 24)
                Text(kind.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            ForEach(items) { candidate in
                HStack(spacing: 10) {
                    CleanupItemLabel(candidate: candidate)
                    Spacer(minLength: 12)
                    Text(candidate.sizeLabel)
                        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                }
            }
            Hint(kind.consequence)
        }
    }
}
