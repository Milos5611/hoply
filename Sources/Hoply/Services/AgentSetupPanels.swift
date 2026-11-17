import AppKit

enum AgentSetupPanels {
    static func chooseFolder(at expected: String, message: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: expected, isDirectory: true)
        panel.prompt = "Allow Access"
        panel.message = message
        NSApp.activateOverOtherApps()
        return await panel.begin() == .OK ? panel.url : nil
    }
}
