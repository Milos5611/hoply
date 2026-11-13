import AgentKit
import SwiftUI

struct CleanupPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var cleanup = model.cleanup
        let historyOff = model.history.unavailableReason != nil
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Clean up", subtitle: subtitle(cleanup)) {
                    CleanupControls()
                }
                if historyOff {
                    Card(prominent: true, tint: .orange) {
                        Label("History is off, so Hoply does not know your projects. Only orphan processes are listed.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.orange)
                    }
                }
                if let report = cleanup.report {
                    CleanupReportCard(report: report)
                }
                ForEach(historyOff ? [CleanupKind.orphanProcess] : CleanupKind.allCases, id: \.self) { kind in
                    CleanupSection(kind: kind)
                }
                if !cleanup.log.isEmpty {
                    CleanupLogCard(entries: cleanup.log)
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $cleanup.isReviewing) {
            CleanupReviewSheet()
        }
        .onAppear {
            if cleanup.scan == nil { cleanup.refresh() }
        }
    }

    private func subtitle(_ cleanup: Cleanup) -> String {
        guard let scan = cleanup.scan else { return "Nothing leaves your Mac without your review" }
        let found = scan.reclaimableBytes > 0 ? "\(Format.bytes(scan.reclaimableBytes)) reclaimable"
                                              : "Nothing to reclaim"
        return "\(found) · last scan \(Format.clock(scan.scannedAt))"
    }
}

private struct CleanupControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cleanup = model.cleanup
        let selected = cleanup.selected
        if cleanup.isScanning || cleanup.isRunning {
            ProgressView()
                .controlSize(.small)
        }
        Button { cleanup.refresh() } label: {
            Label("Scan", systemImage: "arrow.clockwise")
        }
        .disabled(cleanup.isScanning || cleanup.isRunning)
        .tooltip("Look through your projects again")
        Button { cleanup.isReviewing = true } label: {
            Text(selected.isEmpty ? "Review…" : "Review \(CleanupSummary.items(selected.count))…")
        }
        .buttonStyle(.borderedProminent)
        .disabled(selected.isEmpty || cleanup.isRunning)
        .help("Check the list before anything is removed")
    }
}
