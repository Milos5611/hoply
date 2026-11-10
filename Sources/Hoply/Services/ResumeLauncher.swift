import AgentKit
import AppKit

enum ResumeLauncher {
    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Hoply/Resume", directoryHint: .isDirectory)
    }

    static func resume(source: AgentSource, sessionID: String, cwd: String) -> Bool {
        guard let script = writeScript(source: source, sessionID: sessionID, cwd: cwd, in: folder) else { return false }
        prune()
        return NSWorkspace.shared.open(script)
    }

    @discardableResult
    static func prune(in folder: URL = folder, now: Date = Date()) -> [String] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else {
            return []
        }
        let scripts = files.compactMap { file -> (name: String, modified: Date)? in
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let modified = values.contentModificationDate else { return nil }
            return (file.lastPathComponent, modified)
        }
        return ResumeScript.staleFileNames(scripts, now: now).filter { name in
            (try? manager.removeItem(at: folder.appendingPathComponent(name, isDirectory: false))) != nil
        }
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
