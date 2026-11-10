import AgentKit
import AppKit

enum ResumeLauncher {
    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Hoply/Resume", directoryHint: .isDirectory)
    }

    static func resume(source: AgentSource, sessionID: String, cwd: String) -> Bool {
        guard let script = writeScript(source: source, sessionID: sessionID, cwd: cwd, in: folder) else { return false }
        return NSWorkspace.shared.open(script)
    }

    static func writeScript(source: AgentSource, sessionID: String, cwd: String, in folder: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue,
              let name = ResumeScript.fileName(source: source, sessionID: sessionID),
              let text = ResumeScript.script(source: source, sessionID: sessionID, cwd: cwd) else { return nil }
        let file = folder.appendingPathComponent(name, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file
        } catch {
            return nil
        }
    }
}
