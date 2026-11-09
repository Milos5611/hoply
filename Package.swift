// swift-tools-version:5.10
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
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hoply", targets: ["Hoply"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
    ],
    targets: [
        // Platform-neutral core: decoding, state, parsing. No UI.
        .target(name: "AgentKit"),
        // The macOS menu bar app.
        .executableTarget(
            name: "Hoply",
            dependencies: ["AgentKit"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        ),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
