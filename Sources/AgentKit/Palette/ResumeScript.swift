import Foundation

public enum ResumeScript {
    public static let fileExtension = "command"

    public static func isSupported(_ source: AgentSource) -> Bool {
        arguments(for: source, sessionID: "x") != nil
    }

    public static func script(source: AgentSource, sessionID: String, cwd: String?) -> String? {
        guard isPlausibleSessionID(sessionID), let arguments = arguments(for: source, sessionID: sessionID),
              let cwd, cwd.hasPrefix("/"), !cwd.utf8.contains(0), !cwd.contains(where: \.isNewline) else { return nil }
        let command = arguments.map(shellQuoted).joined(separator: " ")
        let folder = shellQuoted(cwd)
        // The second branch covers a launcher that starts the script without the user's interactive
        // PATH: "$0" and "$@" carry the command through the nested shell with no second quoting.
        return """
            #!/bin/zsh
            cd -- \(folder) || { print -r -- "Hoply: cannot open" \(folder); exit 1; }
            if command -v \(shellQuoted(arguments[0])) >/dev/null 2>&1; then
              exec \(command)
            fi
            exec /bin/zsh -ilc 'exec "$0" "$@"' \(command)

            """
    }

    public static func fileName(source: AgentSource, sessionID: String) -> String? {
        guard isPlausibleSessionID(sessionID), isSupported(source) else { return nil }
        return "hoply-resume-\(source.rawValue)-\(sessionID).\(fileExtension)"
    }

    public static func isPlausibleSessionID(_ id: String) -> Bool {
        guard (1...128).contains(id.utf8.count), let first = id.utf8.first, isAlphanumeric(first) else { return false }
        return id.utf8.allSatisfy { isAlphanumeric($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") }
    }

    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func arguments(for source: AgentSource, sessionID: String) -> [String]? {
        switch source {
        case .claudeCode: return ["claude", "--resume", sessionID]
        case .copilotCLI, .copilotIDE, .qwenCode: return nil
        }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}
