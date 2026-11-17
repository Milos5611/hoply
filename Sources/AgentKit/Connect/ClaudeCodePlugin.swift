import Foundation

public struct ClaudeCodePlugin: Equatable, Sendable {
    public static let name = "hoply"
    public static let marketplace = "hoply"
    public static let manifestPath = ".claude-plugin/plugin.json"
    public static let marketplacePath = ".claude-plugin/marketplace.json"
    public static let hooksPath = "hooks/hooks.json"
    public static let defaultVersion = "1.0.0"
    public static let description = "Sends Claude Code's session events to Hoply on this Mac, so Hoply shows live "
        + "sessions, approvals and replies."

    public let port: Int
    public let version: String

    public init(port: Int, version: String = ClaudeCodePlugin.defaultVersion) {
        self.port = port
        self.version = version
    }

    public var hooks: ClaudeCodeHooks { ClaudeCodeHooks(port: port) }

    public var hooksFile: [String: Any] {
        var events: [String: Any] = [:]
        for event in ClaudeCodeHooks.events {
            events[event] = [["hooks": [hooks.hook(for: event)]]]
        }
        return ["description": Self.description, "hooks": events]
    }

    public var manifest: [String: Any] {
        ["name": Self.name, "version": version, "description": Self.description,
         "author": ["name": "Hoply", "url": "https://hoply.dev"], "homepage": "https://hoply.dev", "license": "MIT"]
    }

    public var marketplaceFile: [String: Any] {
        ["name": Self.marketplace, "owner": ["name": "Hoply", "url": "https://hoply.dev"],
         "plugins": [["name": Self.name, "source": "./", "version": version, "description": Self.description]]]
    }

    public var files: [String: Data] {
        [Self.manifestPath: SettingsJSON.encode(manifest),
         Self.marketplacePath: SettingsJSON.encode(marketplaceFile),
         Self.hooksPath: SettingsJSON.encode(hooksFile)]
    }

    public static func installCommands(folder: String) -> [String] {
        ["/plugin marketplace add \(folder)", "/plugin install \(name)@\(marketplace)"]
    }

    public var environmentSnippet: String {
        String(decoding: SettingsJSON.encode(["env": hooks.environment]), as: UTF8.self)
    }

    public static func enabledKeys(inSettings settings: [String: Any]) -> [String] {
        guard let enabled = settings["enabledPlugins"] as? [String: Any] else { return [] }
        return enabled.compactMap { key, value in
            guard key.hasPrefix(name + "@"), let on = value as? NSNumber, SettingsJSON.isBool(on), on.boolValue else {
                return nil
            }
            return key
        }
        .sorted()
    }

    public static func isInstalledTwice(inSettings settings: [String: Any]) -> Bool {
        !ClaudeCodeHooks.ourHooks(in: settings).isEmpty && !enabledKeys(inSettings: settings).isEmpty
    }

    // installed_plugins.json: {"plugins": {"hoply@<marketplace>": [{"scope": "user", "installPath": …}]}}.
    // settings.json's enabledPlugins is the user scope, so its install wins.
    public static func installPath(forKeys keys: [String], installedPlugins: [String: Any]) -> String? {
        let plugins = installedPlugins["plugins"] as? [String: Any] ?? [:]
        let installs = keys.flatMap { plugins[$0] as? [Any] ?? [] }.compactMap { $0 as? [String: Any] }
        let chosen = installs.first { $0["scope"] as? String == "user" } ?? installs.first
        return chosen?["installPath"] as? String
    }

    public func status(installedHooks: [String: Any]?) -> ConnectionStatus {
        guard let installed = installedHooks?["hooks"] else { return .notConnected }
        return SettingsJSON.same(installed, hooksFile["hooks"] as Any) ? .connected : .outdated
    }
}
