import AgentKit
import SwiftUI

struct ProjectEditBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.projectEdits.error {
            Card(prominent: true, tint: .red) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { model.projectEdits.clearError() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
            }
        }
    }
}

struct EditConfirmation<Extra: View>: View {
    @Environment(AppModel.self) private var model
    let confirmation: ProjectEdits.Confirmation
    @ViewBuilder var extra: Extra

    var body: some View {
        let edits = model.projectEdits
        VStack(alignment: .leading, spacing: 10) {
            extra
            Text(ProjectEditText.message(confirmation))
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                if edits.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Cancel") { edits.cancelConfirmation() }
                    .keyboardShortcut(.cancelAction)
                Button(ProjectEditText.confirmTitle(confirmation)) { edits.confirm() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
            .disabled(edits.isWorking)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.5))
    }
}

extension EditConfirmation where Extra == EmptyView {
    init(confirmation: ProjectEdits.Confirmation) {
        self.init(confirmation: confirmation) { EmptyView() }
    }
}

struct ProjectMenu<MenuLabel: View>: View {
    let projects: [ProjectRef]
    let choose: (ProjectRef) -> Void
    @ViewBuilder var label: MenuLabel

    var body: some View {
        Menu {
            ForEach(projects) { project in
                Button { choose(project) } label: {
                    Text("\(project.title)  –  \(Format.path(project.root))")
                }
            }
        } label: {
            label
        }
        .disabled(projects.isEmpty)
    }
}

// MARK: - Suggestions

struct MergeSuggestionCard: View {
    @Environment(AppModel.self) private var model
    let suggestion: MergeSuggestion

    var body: some View {
        let edits = model.projectEdits
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    IconTile(symbol: "arrow.triangle.merge", tint: .orange, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(suggestion.summary)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("They look like clones of one repository. Merged, they show as one project.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    if confirmation == nil {
                        HStack(spacing: 8) {
                            Button("Merge…") { edits.beginMerge(suggestion) }
                                .help("Choose which project stays, then confirm")
                            Button("Dismiss") { edits.dismiss(suggestion) }
                                .help("Hide this suggestion. Dismissed suggestions can be brought back below.")
                        }
                        .disabled(edits.isWorking)
                    }
                }
                if let confirmation, case .merge(_, let target, _) = confirmation.action {
                    EditConfirmation(confirmation: confirmation) {
                        HStack(spacing: 8) {
                            Text("Keep")
                                .font(.system(size: 12.5, weight: .medium))
                            Picker("Keep", selection: Binding(get: { target.id }, set: { id in
                                if let kept = suggestion.projects.first(where: { $0.id == id }) {
                                    edits.beginMerge(suggestion, keeping: kept)
                                }
                            })) {
                                ForEach(suggestion.projects) { project in
                                    Text(option(project)).tag(project.id)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var confirmation: ProjectEdits.Confirmation? {
        guard let pending = model.projectEdits.confirmation, case .merge(_, _, let asked) = pending.action,
              asked?.id == suggestion.id else { return nil }
        return pending
    }

    private func option(_ project: ProjectRef) -> String {
        var parts = [project.title, Format.path(project.root)]
        if let usage = model.projectEdits.usage[project.id] {
            parts.append(usage.sessions == 1 ? "1 session" : "\(Format.count(usage.sessions)) sessions")
            parts.append(Format.spend(usage.totals))
        }
        return parts.joined(separator: " · ")
    }
}

struct SuggestionRestore: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let edits = model.projectEdits
        HStack(spacing: 8) {
            Button("Bring back dismissed merge suggestions") { edits.restoreSuggestions() }
                .buttonStyle(.link)
                .help("Hoply suggests a merge when two projects share a git origin")
            if let notice = edits.notice {
                Text(notice)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
    }
}

// MARK: - Project detail

struct ProjectGroupingCard: View {
    @Environment(AppModel.self) private var model
    let project: ProjectRef

    var body: some View {
        let edits = model.projectEdits
        let merged = edits.merged(into: project)
        let folders = edits.folders(of: project)
        DashboardCard(title: "Merges and folders", subtitle: "What counts as \(project.title)") {
            ProjectMenu(projects: edits.targets(excluding: project), choose: { edits.beginMerge(project, into: $0) }) {
                Label("Merge into…", systemImage: "arrow.triangle.merge")
            }
            .fixedSize()
            .disabled(edits.isWorking)
            .help("Move this project's sessions and usage into another project")
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                if let confirmation {
                    EditConfirmation(confirmation: confirmation)
                }
                if !merged.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Merged into this project")
                        ForEach(merged) { entry in
                            row(title: entry.project.title, detail: Format.path(entry.project.root), action: "Unmerge",
                                help: "Give \(entry.project.title) its own project again") {
                                edits.beginUnmerge(entry)
                            } icon: {
                                ProjectIcon(project: entry.project, size: 24)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Folders")
                    row(title: Format.path(project.root), detail: "Project root", action: nil, help: "") {} icon: {
                        IconTile(symbol: "folder.fill", tint: .blue, size: 24)
                    }
                    ForEach(folders) { folder in
                        row(title: Format.path(folder.path), detail: "Added by you", action: "Remove",
                            help: "Stop counting this folder under \(project.title)") {
                            edits.beginRemoving(folder)
                        } icon: {
                            IconTile(symbol: "folder.badge.plus", tint: .teal, size: 24)
                        }
                    }
                    HStack(spacing: 10) {
                        Button { edits.addFolder(to: project) } label: {
                            Label("Add folder…", systemImage: "plus")
                        }
                        .disabled(edits.isWorking)
                        Hint("Sessions started in an added folder count under this project.")
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var confirmation: ProjectEdits.Confirmation? {
        guard let pending = model.projectEdits.confirmation else { return nil }
        switch pending.action {
        case .merge(let sources, _, let suggestion):
            return suggestion == nil && sources.contains { $0.id == project.id } ? pending : nil
        case .unmerge(let merged):
            return merged.into.id == project.id ? pending : nil
        case .removeFolder(let folder):
            return folder.project.id == project.id ? pending : nil
        }
    }

    private func row(title: String, detail: String, action: String?, help: String, perform: @escaping () -> Void,
                     @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: 10) {
            icon()
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let action {
                Button(action, action: perform)
                    .controlSize(.small)
                    .disabled(model.projectEdits.isWorking)
                    .help(help)
            }
        }
    }
}

// MARK: - Session detail

struct SessionProjectControls: View {
    @Environment(AppModel.self) private var model
    let session: SessionSummary

    var body: some View {
        let edits = model.projectEdits
        let assigned = edits.assignment(of: session.key) != nil
        let targets = edits.targets(excluding: session.project)
        if !targets.isEmpty || assigned {
            HStack(spacing: 8) {
                ProjectMenu(projects: targets, choose: { edits.assign(session.key, to: $0) }) {
                    Text(session.project == nil ? "Assign to project…" : "Move to project…")
                }
                .fixedSize()
                .help("Count this session and its usage under another project")
                if assigned {
                    Button("Undo") { edits.unassign(session.key) }
                        .help("You assigned this session. Undo puts it back in the project of its folder.")
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .disabled(edits.isWorking)
        }
    }
}
