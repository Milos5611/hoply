import AgentKit
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    /// `--snapshot` can't draw the sidebar's material, vibrant text or selection (the window server
    /// composites them), so snapshots use a plain stand-in for the sidebar.
    var plainSidebar = false

    var body: some View {
        let history = model.history
        let selection = Binding<DashboardPage?>(get: { history.page }, set: { page in
            if let page { history.select(page) }
        })
        if plainSidebar {
            HStack(spacing: 0) {
                PlainSidebar(selection: selection)
                    .frame(width: 210)
                Divider()
                detail(history.page)
            }
        } else {
            NavigationSplitView {
                List(selection: selection) {
                    Section("History") {
                        ForEach(DashboardPage.allCases) { page in
                            Label(page.title, systemImage: page.symbol)
                                .tag(page)
                        }
                    }
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .bottom) {
                    SidebarStatus()
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            } detail: {
                detail(history.page)
            }
        }
    }

    private func detail(_ page: DashboardPage) -> some View {
        Group {
            switch page {
            case .overview: OverviewPage()
            case .projects: ProjectsPage()
            case .sessions: SessionsPage()
            case .spending: SpendingPage()
            }
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PlainSidebar: View {
    @Binding var selection: DashboardPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("History")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(DashboardPage.allCases) { page in
                Label(page.title, systemImage: page.symbol)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(selection == page ? 0.10 : 0)))
            }
            Spacer()
            SidebarStatus()
                .padding(.horizontal, -6)
        }
        .padding(.horizontal, 10)
        .padding(.top, 18)
        .background(Color.primary.opacity(0.03))
    }
}

struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        HStack(spacing: 7) {
            if history.progress.isBackfilling {
                ProgressView(value: history.progress.fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                Text("Indexing \(Format.percent(history.progress.fraction))")
            } else {
                Circle()
                    .fill(color(history))
                    .frame(width: 7, height: 7)
                Text(text(history))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .help(history.unavailableReason ?? history.progress.lastError ?? "Usage ledger")
    }

    private func text(_ history: History) -> String {
        switch history.status {
        case .off, .opening: return "Opening ledger…"
        case .unavailable: return "History off"
        case .ready: return history.progress.lastError == nil ? "Ledger up to date" : "Ledger: last read failed"
        }
    }

    private func color(_ history: History) -> Color {
        switch history.status {
        case .off, .opening: return .secondary
        case .unavailable: return .red
        case .ready: return history.progress.lastError == nil ? .green : .orange
        }
    }
}
