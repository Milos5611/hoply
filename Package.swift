// swift-tools-version:6.2
import Foundation
import PackageDescription

// Embed Info.plist into the executable so `swift run` gets the same App Transport Security
// exceptions (plain HTTP to the vLLM box on the LAN) as the bundled .app.
func plist(_ name: String) -> String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/Hoply/\(name)")
        .path
}

func embedding(_ name: String) -> [String] {
    ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", plist(name)]
}

let package = Package(
    name: "Hoply",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hoply", targets: ["Hoply"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "AgentSystem", targets: ["AgentSystem"]),
    ],
    traits: [
        .trait(name: "Sparkle"),
        .trait(name: "AppStore"),
        .default(enabledTraits: ["Sparkle"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        // Platform-neutral core: decoding, state, parsing. No UI, no new I/O.
        .target(name: "AgentKit"),
        // macOS I/O adapters (SQLite, files, processes, Keychain) feeding AgentKit types. No UI.
        .target(
            name: "AgentSystem",
            dependencies: ["AgentKit"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The macOS menu bar app.
        .executableTarget(
            name: "Hoply",
            dependencies: [
                "AgentKit", "AgentSystem",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(traits: ["Sparkle"])),
            ],
            exclude: ["Info.plist", "Info-AppStore.plist", "Hoply.icon"],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [
                .unsafeFlags(embedding("Info.plist")
                             // Hoply.app/Contents/Frameworks/Sparkle.framework; swift run finds it through @loader_path.
                             + ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                             .when(traits: ["Sparkle"])),
                .unsafeFlags(embedding("Info-AppStore.plist"), .when(traits: ["AppStore"])),
                // SwiftPM records the deployment target as the SDK version, and AppKit picks the
                // Liquid Glass design from it: 14.0 there would give macOS 26+ the old look.
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos",
                              "-Xlinker", "14.0", "-Xlinker", "26.0"]),
            ]
        ),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AgentSystemTests",
            dependencies: ["AgentKit", "AgentSystem"]
        ),
    ]
)
