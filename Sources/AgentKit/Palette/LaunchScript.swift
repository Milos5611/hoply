import Foundation

public enum LaunchScript {
    public static let maxPromptLength = 4000

    public static func canStart(_ source: AgentSource) -> Bool {
        source.info.startArguments(prompt: "x") != nil
    }

    public static func canContinue(_ source: AgentSource) -> Bool {
        source.info.continueArguments(sessionID: "x", prompt: "x") != nil
    }

    public static func normalizedPrompt(_ text: String?) -> String? {
        guard let text else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: lines.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar.properties.generalCategory != .control
        })
        let prompt = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    public static func isShellMode(_ prompt: String) -> Bool {
        normalizedPrompt(prompt)?.first == "!"
    }

    public static func arguments(source: AgentSource, sessionID: String?, prompt: String) -> [String]? {
        guard let prompt = normalizedPrompt(prompt), prompt.count <= maxPromptLength, prompt.first != "!" else {
            return nil
        }
        // Claude Code runs a subcommand when its prompt equals one ("purge", "update"), even after `--`;
        // no command name holds whitespace, so a one-word prompt gets a trailing space.
        let argument = prompt.contains(where: \.isWhitespace) ? prompt : prompt + " "
        guard let sessionID else { return source.info.startArguments(prompt: argument) }
        guard ResumeScript.isPlausibleSessionID(sessionID) else { return nil }
        return source.info.continueArguments(sessionID: sessionID, prompt: argument)
    }

    // The script deletes itself once zsh has it open, so the prompt doesn't stay on disk.
    public static func script(source: AgentSource, sessionID: String?, prompt: String, cwd: String) -> String? {
        guard let arguments = arguments(source: source, sessionID: sessionID, prompt: prompt) else { return nil }
        return ResumeScript.script(arguments: arguments, cwd: cwd, preamble: "rm -f -- \"$0\"\n")
    }

    public static func fileName(source: AgentSource, answerID: String) -> String {
        "hoply-launch-\(source.rawValue)-\(FNV1a.hex64(answerID.utf8)).\(ResumeScript.fileExtension)"
    }

    static func isScriptName(_ name: String, source: AgentSource) -> Bool {
        let prefix = "hoply-launch-\(source.rawValue)-"
        let suffix = "." + ResumeScript.fileExtension
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let token = name.dropFirst(prefix.count).dropLast(suffix.count)
        return token.utf8.count == 16 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
