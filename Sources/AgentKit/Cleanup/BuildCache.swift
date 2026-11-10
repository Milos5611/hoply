import Foundation

public struct BuildCache: Sendable, Equatable {
    public let directoryName: String
    public let label: String
    public let markerFile: String?
    public let isOptIn: Bool

    init(_ directoryName: String, _ label: String, markerFile: String? = nil, isOptIn: Bool = false) {
        self.directoryName = directoryName
        self.label = label
        self.markerFile = markerFile
        self.isOptIn = isOptIn
    }

    public static let nodeModules = BuildCache("node_modules", "node_modules", isOptIn: true)

    public static let catalogue: [BuildCache] = [
        BuildCache(".next", "Next.js build"),
        BuildCache(".nuxt", "Nuxt build"),
        BuildCache(".vite", "Vite cache"),
        BuildCache(".turbo", "Turborepo cache"),
        BuildCache(".parcel-cache", "Parcel cache"),
        BuildCache(".svelte-kit", "SvelteKit build"),
        BuildCache(".astro", "Astro cache"),
        BuildCache(".angular", "Angular cache"),
        BuildCache(".build", "Swift build"),
        BuildCache(".pytest_cache", "pytest cache"),
        BuildCache(".mypy_cache", "mypy cache"),
        BuildCache(".ruff_cache", "Ruff cache"),
        BuildCache("DerivedData", "Xcode DerivedData"),
        BuildCache("target", "Cargo target", markerFile: "Cargo.toml"),
        nodeModules,
    ]

    public static func named(_ directoryName: String) -> BuildCache? {
        catalogue.first { $0.directoryName == directoryName }
    }

    public static func match(directoryName: String, includeNodeModules: Bool,
                             hasSibling: (String) -> Bool) -> BuildCache? {
        guard let cache = named(directoryName), !cache.isOptIn || includeNodeModules else { return nil }
        if let marker = cache.markerFile, !hasSibling(marker) { return nil }
        return cache
    }

    public static func isWalkable(directoryName: String) -> Bool {
        directoryName != ".git" && directoryName != nodeModules.directoryName
    }
}
