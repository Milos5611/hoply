import AgentKit
import SwiftUI

struct CleanupReportCard: View {
    @Environment(AppModel.self) private var model
    let report: CleanupReport

    var body: some View {
        let kept = report.skipped + report.failed
        Card(prominent: true, tint: report.removed.isEmpty ? .orange : .green, padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(CleanupSummary.headline(report),
                          systemImage: report.removed.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(report.removed.isEmpty ? Color.orange : Color.green)
                    Spacer(minLength: 8)
                    Button { model.cleanup.dismissReport() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .tooltip("Dismiss")
                }
                ForEach(report.removed) { item in
                    row(item, symbol: "checkmark", tint: .green)
                }
                if !kept.isEmpty {
                    SectionTitle("Left in place")
                    ForEach(kept) { item in
                        row(item, symbol: "minus", tint: .orange)
                    }
                }
                if report.removed.contains(where: { !$0.candidate.kind.isProcess }) {
                    Hint("Changed your mind? Use Put Back in the Trash.")
                }
            }
        }
    }

    private func row(_ item: CleanupReport.Item, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(item.candidate.title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Text(item.outcome.explanation ?? item.candidate.facts)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if item.outcome == .trashed {
                Text(item.candidate.sizeLabel)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CleanupLogCard: View {
    let entries: [CleanupLogEntry]

    var body: some View {
        DashboardCard(title: "Recently cleaned", subtitle: "From Hoply's clean up log") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: entry.kind.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(entry.kind.tint)
                            .frame(width: 16)
                        Text(entry.detail ?? entry.kind.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        Text(Format.path(entry.path))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let bytes = entry.bytes {
                            Text(Format.bytes(bytes))
                                .font(.system(size: 12).monospacedDigit())
                        }
                        Text(Format.shortWhen(entry.timestamp))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
