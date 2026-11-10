// swift-tools-version:6.2
import Foundation
import PackageDescription

// Embed Info.plist into the executable so `swift run` gets the same App Transport Security
// exceptions (plain HTTP to the vLLM box on the LAN) as the bundled .app.
let infoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/Hoply/Info.plist")
    .path

let package = Package(
    name: "Hoply",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Hoply", targets: ["Hoply"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "AgentSystem", targets: ["AgentSystem"]),
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
            dependencies: ["AgentKit", "AgentSystem", .product(name: "Sparkle", package: "Sparkle")],
            exclude: ["Info.plist", "Hoply.icon"],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", infoPlist,
                              // Hoply.app/Contents/Frameworks/Sparkle.framework; swift run finds it through @loader_path.
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
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
