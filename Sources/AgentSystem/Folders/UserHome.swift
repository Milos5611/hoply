import AgentKit
import Darwin
import Foundation

// Sandboxed, homeDirectoryForCurrentUser, NSHomeDirectory(), $HOME and expandingTildeInPath all give the
// container; the agents' folders and project paths live in the account's real home.
public enum UserHome {
    public static let path: String = passwordEntryHome() ?? NSHomeDirectory()

    public static func expandingTilde(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~/") { return HomePath.expandingTilde(path, home: Self.path) }
        return path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
    }

    public static func abbreviating(_ path: String) -> String {
        HomePath.abbreviating(path, home: Self.path)
    }

    static func passwordEntryHome() -> String? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let suggested = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
        var buffer = [CChar](repeating: 0, count: suggested > 0 ? suggested : 16_384)
        guard getpwuid_r(getuid(), &entry, &buffer, buffer.count, &result) == 0, result != nil,
              let directory = entry.pw_dir else { return nil }
        let home = String(cString: directory)
        return home.hasPrefix("/") ? home : nil
    }
}
