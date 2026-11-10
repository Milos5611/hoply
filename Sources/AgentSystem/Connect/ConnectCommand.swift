import AgentKit
import Foundation

public enum ConnectCommand {
    public static let usage = "Usage: Hoply --connect|--disconnect [claude-code] [copilot-cli]"

    public static func isRequested(_ arguments: [String]) -> Bool {
        arguments.contains("--connect") || arguments.contains("--disconnect")
    }

    public static func run(arguments: [String],
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           settings: AppSettings,
                           home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                           now: @escaping @Sendable () -> Date = { Date() },
                           output: (String) -> Void = { print($0) },
                           errors: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> Int32 {
        guard let flag = arguments.first, flag == "--connect" || flag == "--disconnect" else {
            errors(usage)
            return 2
        }
        let connecting = flag == "--connect"
        var named: [ConnectableAgent] = []
        for name in arguments.dropFirst() {
            guard let agent = ConnectableAgent(rawValue: name) else {
                let known = ConnectableAgent.allCases.map(\.rawValue).joined(separator: ", ")
                errors("Unknown agent \"\(name)\" (known: \(known)).\n\(usage)")
                return 2
            }
            if !named.contains(agent) { named.append(agent) }
        }

        let port: Int
        if let raw = environment["HOPLY_PORT"], !raw.isEmpty {
            guard let value = Int(raw), HoplyEndpoint.isValidPort(value) else {
                errors("HOPLY_PORT must be a port number from 1 to 65535, not \"\(raw)\".")
                return 2
            }
            port = value
        } else {
            guard HoplyEndpoint.isValidPort(settings.port) else {
                errors("The saved port \(settings.port) is not valid; set HOPLY_PORT.")
                return 2
            }
            port = settings.port
        }

        // An explicit environment variable wins over the app's saved folder, so a scratch run never edits the real one.
        let connector = AgentConnector(
            claudeConfigDirectory: AgentConnector.directory(
                environment["CLAUDE_CONFIG_DIR"] ?? "",
                default: AgentConnector.directory(settings.claudeConfigDir, default: home + "/.claude")),
            copilotHome: AgentConnector.directory(
                environment["COPILOT_HOME"] ?? "",
                default: AgentConnector.directory(settings.copilotHome, default: home + "/.copilot")),
            port: port, now: now)

        var failed = false
        for agent in named.isEmpty ? ConnectableAgent.allCases : named {
            if named.isEmpty, !connector.isInstalled(agent) {
                output("\(agent.displayName): not found, skipped")
                continue
            }
            do {
                let outcome = connecting ? try connector.connect(agent) : try connector.disconnect(agent)
                output(line(for: outcome, connecting: connecting, endpoint: HoplyEndpoint.baseURL(port: port)))
            } catch {
                errors("\(agent.displayName): \(error.message)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    static func line(for outcome: ConnectOutcome, connecting: Bool, endpoint: String) -> String {
        let name = outcome.agent.displayName
        let path = outcome.path
        guard outcome.changed else {
            return connecting ? "\(name): already connected (\(path))" : "\(name): not connected, nothing to change (\(path))"
        }
        let detail = [path] + (outcome.backupPath.map { ["backup: \($0)"] } ?? [])
            + (outcome.renamedPath.map { ["renamed to \(($0 as NSString).lastPathComponent)"] } ?? [])
        let restart = connecting && outcome.agent == .claudeCode ? "; restart running sessions" : ""
        let verb = connecting ? "connected to \(endpoint)" : "disconnected"
        return "\(name): \(verb)\(restart) (\(detail.joined(separator: ", ")))"
    }
}
