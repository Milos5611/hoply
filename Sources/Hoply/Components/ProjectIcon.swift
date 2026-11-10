import AgentKit
import SwiftUI

struct ProjectIcon: View {
    var kind: ProjectKind?
    let title: String
    var key: String?
    var hasFolder = true
    var size: CGFloat = 30

    var body: some View {
        switch kind {
        case .repo, .folder:
            MonogramTile(title: title, key: key ?? title, size: size)
        case .home, .scratch:
            IconTile(projectKind: kind, size: size)
        case nil:
            if hasFolder {
                MonogramTile(title: title, key: key ?? title, size: size)
            } else {
                IconTile(projectKind: nil, size: size)
            }
        }
    }
}

extension ProjectIcon {
    init(project: ProjectRef?, size: CGFloat = 30) {
        self.init(kind: project?.kind, title: project?.title ?? "", key: project?.root, hasFolder: project != nil,
                  size: size)
    }
}

struct MonogramTile: View {
    let title: String
    let key: String
    var size: CGFloat = 30

    private static let palette: [Color] = [
        Color(red: 0.25, green: 0.47, blue: 0.96), Color(red: 0.45, green: 0.36, blue: 0.90),
        Color(red: 0.72, green: 0.34, blue: 0.86), Color(red: 0.91, green: 0.33, blue: 0.55),
        Color(red: 0.90, green: 0.38, blue: 0.27), Color(red: 0.88, green: 0.56, blue: 0.12),
        Color(red: 0.36, green: 0.66, blue: 0.24), Color(red: 0.12, green: 0.64, blue: 0.52),
        Color(red: 0.10, green: 0.60, blue: 0.78),
    ]

    var body: some View {
        let letters = Monogram.letters(for: title)
        let color = Self.palette[Monogram.paletteIndex(for: key, count: Self.palette.count)]
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Text(letters)
            .font(.system(size: size * (letters.count > 1 ? 0.38 : 0.46), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(shape.fill(color.gradient))
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
    }
}
