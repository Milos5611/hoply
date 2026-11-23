import SwiftUI

struct MacTag: View {
    let name: String?

    var body: some View {
        let title = name ?? "Another Mac"
        HStack(spacing: 3) {
            Image(systemName: Self.symbol(for: title))
                .font(.system(size: 8.5, weight: .semibold))
            Text(title)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .foregroundStyle(.teal)
        .background(Capsule().fill(Color.teal.opacity(0.14)))
        .fixedSize()
        .help("From \(title), through iCloud")
    }

    static func symbol(for name: String) -> String {
        name.localizedCaseInsensitiveContains("book") ? "laptopcomputer" : "desktopcomputer"
    }
}
