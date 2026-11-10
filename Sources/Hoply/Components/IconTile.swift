import AgentKit
import SwiftUI

struct IconTile: View {
    let symbol: String
    var tint: Color = .secondary
    var size: CGFloat = 30

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(shape.fill(colorScheme == .dark ? Color.white.opacity(0.10) : .white)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.05), radius: 1.5, y: 0.5))
            .overlay(shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 0.5))
    }
}

extension IconTile {
    init(projectKind kind: ProjectKind?, size: CGFloat = 30) {
        self.init(symbol: Self.symbol(for: kind), tint: Self.tint(for: kind), size: size)
    }

    static func symbol(for kind: ProjectKind?) -> String {
        switch kind {
        case .repo: return "folder.fill"
        case .folder: return "folder"
        case .home: return "house.fill"
        case .scratch: return "scribble"
        case nil: return "questionmark.folder"
        }
    }

    static func tint(for kind: ProjectKind?) -> Color {
        switch kind {
        case .repo, .folder: return .blue
        case .home: return .indigo
        case .scratch: return .orange
        case nil: return .secondary
        }
    }
}
