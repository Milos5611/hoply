import AgentKit
import SwiftUI

struct PaletteView: View {
    static let size = CGSize(width: 640, height: 438)

    var plainBackground = false

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searching: Bool
    @State private var hovered: String?

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    var body: some View {
        let palette = model.palette
        let rows = palette.rows()
        let selected = palette.selection(in: rows)
        VStack(spacing: 0) {
            searchField(palette)
            Divider()
            if rows.isEmpty {
                noResults(PaletteQuery(palette.query))
            } else {
                results(rows, selected: selected, palette: palette)
            }
            Divider()
            PaletteFooter(selected: selected?.entry)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .modifier(PaletteSurface(shape: shape, solid: plainBackground || reduceTransparency))
        .overlay(shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 0.5))
        .onAppear { searching = true }
    }

    private func searchField(_ palette: Palette) -> some View {
        HStack(spacing: 10) {
            Image(systemName: PaletteQuery(palette.query).actionsOnly ? "chevron.right" : "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            TextField("Search sessions, projects, dev servers and pages", text: Binding(get: { palette.query },
                                                                                        set: { palette.setQuery($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searching)
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
    }

    private func results(_ rows: [Palette.Row], selected: Palette.Row?, palette: Palette) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        PaletteRow(row: row, isSelected: row.id == selected?.id, isHovered: row.id == hovered)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside {
                                    hovered = row.id
                                } else if hovered == row.id {
                                    hovered = nil
                                }
                            }
                            .onTapGesture { palette.run(row, secondary: NSEvent.modifierFlags.contains(.command)) }
                            .id(row.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: selected?.id) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func noResults(_ query: PaletteQuery) -> some View {
        VStack(spacing: 6) {
            Image(systemName: query.actionsOnly ? "chevron.right" : "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(query.actionsOnly ? "No action matches “\(query.text)”" : "No matches for “\(query.text)”")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(query.actionsOnly ? "Remove > to search sessions, projects and pages too."
                                   : "Sessions and projects come from the usage history. Type > for actions.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PaletteSurface: ViewModifier {
    let shape: RoundedRectangle
    let solid: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if solid {
            content
                .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .clipShape(shape)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 14, y: 6)
        } else if #available(macOS 26, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .clipShape(shape)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 14, y: 6)
        }
    }
}

struct PaletteRow: View {
    let row: Palette.Row
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        let entry = row.entry
        HStack(spacing: 10) {
            icon(entry.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = entry.item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let status = entry.status {
                StatePill(status: status, failed: entry.failed)
            }
            if isSelected {
                HStack(spacing: 5) {
                    Text(entry.primary.label)
                    KeyCap("↩")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            } else {
                Text(Self.kindLabel(entry.item.kind))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(isSelected ? 0.09 : isHovered ? 0.045 : 0)))
    }

    private var title: AttributedString {
        var text = AttributedString(row.entry.item.title)
        for range in row.result.titleStringRanges {
            guard let matched = Range(range, in: text) else { continue }
            text[matched].font = .system(size: 13.5, weight: .bold)
        }
        return text
    }

    @ViewBuilder
    private func icon(_ icon: Palette.Icon) -> some View {
        switch icon {
        case .project(let project): ProjectIcon(project: project, size: 28)
        case .source(let source): SourceBadge(source: source, size: 28)
        case .symbol(let symbol): IconTile(symbol: symbol, size: 28)
        }
    }

    static func kindLabel(_ kind: PaletteItem.Kind) -> String {
        switch kind {
        case .session: return "Session"
        case .project: return "Project"
        case .devServer: return "Dev server"
        case .page: return "Page"
        case .action: return "Action"
        }
    }
}

struct KeyCap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(Color.primary.opacity(0.08)))
    }
}

struct PaletteFooter: View {
    let selected: Palette.Entry?

    var body: some View {
        HStack(spacing: 14) {
            hint(["↑", "↓"], "Navigate")
            if let selected {
                hint(["↩"], selected.primary.label)
                if let secondary = selected.secondary {
                    hint(["⌘", "↩"], secondary.label)
                }
            }
            Spacer(minLength: 8)
            hint([">"], "Actions")
            hint(["esc"], "Close")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { KeyCap($0) }
            Text(label)
                .padding(.leading, 2)
        }
        .fixedSize()
    }
}
