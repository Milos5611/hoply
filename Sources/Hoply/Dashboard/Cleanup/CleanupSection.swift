import AgentKit
import SwiftUI

struct CleanupSection: View {
    static let keptLimit = 8

    @Environment(AppModel.self) private var model
    let kind: CleanupKind
    @State private var showsKept = false

    var body: some View {
        let cleanup = model.cleanup
        let candidates = cleanup.candidates(of: kind)
        let eligible = candidates.filter(\.isEligible)
        let kept = candidates.filter { !$0.isEligible }
        DashboardCard(title: kind.title, subtitle: kind.rule) {
            trailing(eligible, cleanup: cleanup)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if eligible.isEmpty {
                    Text(emptyText(cleanup, kept: kept.count))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                ForEach(eligible) { candidate in
                    CleanupRow(candidate: candidate)
                }
                if !kept.isEmpty {
                    keptList(kept)
                }
            }
        }
    }

    @ViewBuilder
    private func trailing(_ eligible: [CleanupCandidate], cleanup: Cleanup) -> some View {
        if kind == .buildCache {
            Toggle("Include node_modules", isOn: Binding(get: { model.settings.cleanupIncludesNodeModules },
                                                         set: { model.setCleanupIncludesNodeModules($0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("Offer node_modules folders too; reinstalling them needs the network")
        }
        if eligible.count > 1 {
            let allSelected = eligible.allSatisfy(cleanup.isSelected)
            Button(allSelected ? "Select none" : "Select all") { cleanup.setSelected(eligible, !allSelected) }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
    }

    private func keptList(_ kept: [CleanupCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showsKept.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: showsKept ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("\(kept.count) kept")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("What Hoply leaves alone, and why")
            if showsKept {
                ForEach(kept.prefix(Self.keptLimit)) { candidate in
                    CleanupKeptRow(candidate: candidate)
                }
                if kept.count > Self.keptLimit {
                    Hint("and \(kept.count - Self.keptLimit) more")
                        .padding(.leading, 28)
                }
            }
        }
    }

    private func emptyText(_ cleanup: Cleanup, kept: Int) -> String {
        if kind.isProcess { return "No orphan processes" }
        if cleanup.scan == nil { return cleanup.isScanning ? "Scanning…" : "Not scanned yet" }
        return kept == 0 ? "Nothing found" : "Nothing to clean up"
    }
}

private struct CleanupRow: View {
    @Environment(AppModel.self) private var model
    let candidate: CleanupCandidate

    var body: some View {
        let cleanup = model.cleanup
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(get: { cleanup.isSelected(candidate) },
                                     set: { cleanup.setSelected(candidate, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(cleanup.isRunning)
            CleanupItemLabel(candidate: candidate)
            Spacer(minLength: 12)
            Text(candidate.sizeLabel)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
            if let path = candidate.revealPath {
                Button { WorkspaceActions.revealInFinder(path) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .tooltip("Show in Finder")
            }
        }
    }
}

private struct CleanupKeptRow: View {
    let candidate: CleanupCandidate

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                CleanupItemLabel(candidate: candidate)
                Text(candidate.keptBecause)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Text(candidate.sizeLabel)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct CleanupItemLabel: View {
    let candidate: CleanupCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(candidate.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text(candidate.facts)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(candidate.revealPath.map(Format.path) ?? "")
        }
    }
}
