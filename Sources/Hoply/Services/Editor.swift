import AppKit

struct Editor: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL

    static let defaultsKey = "HoplyDefaultEditor"

    private static let known: [(id: String, name: String)] = [
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.microsoft.VSCode", "VS Code"),
        ("com.microsoft.VSCodeInsiders", "VS Code Insiders"),
        ("dev.zed.Zed", "Zed"),
        ("dev.zed.Zed-Preview", "Zed Preview"),
        ("com.jetbrains.intellij", "IntelliJ IDEA"),
        ("com.jetbrains.intellij.ce", "IntelliJ IDEA CE"),
        ("com.jetbrains.WebStorm", "WebStorm"),
        ("com.jetbrains.pycharm", "PyCharm"),
        ("com.jetbrains.pycharm.ce", "PyCharm CE"),
        ("com.jetbrains.rider", "Rider"),
        ("com.jetbrains.goland", "GoLand"),
        ("com.jetbrains.CLion", "CLion"),
        ("com.jetbrains.PhpStorm", "PhpStorm"),
        ("com.jetbrains.rubymine", "RubyMine"),
        ("com.jetbrains.rustrover", "RustRover"),
        ("com.google.android.studio", "Android Studio"),
        ("com.apple.dt.Xcode", "Xcode"),
    ]

    static func installed() -> [Editor] {
        known.compactMap { entry in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.id).map {
                Editor(id: entry.id, name: entry.name, url: $0)
            }
        }
    }
}
