import Foundation

public enum AgentConfigWrites: Equatable, Sendable {
    case always
    case withinReadWriteGrant
}

public enum Edition: String, CaseIterable, Sendable {
    case direct
    case appStore

    public static let current: Edition = {
        #if AppStore
        .appStore
        #else
        .direct
        #endif
    }()

    public var agentConfigWrites: AgentConfigWrites { self == .direct ? .always : .withinReadWriteGrant }

    public func writesAgentConfig(at path: String, grants: [FolderGrant]) -> Bool {
        switch agentConfigWrites {
        case .always: return true
        case .withinReadWriteGrant: return grants.contains { $0.covers(path, needsWrite: true) }
        }
    }

    public var needsFolderGrants: Bool { self == .appStore }
    public var opensTerminal: Bool { self == .direct }
    public var offersPhoneLaunch: Bool { opensTerminal }
}

public enum HomePath {
    public static func expandingTilde(_ path: String, home: String) -> String {
        let home = PathScope.normalized(home)
        if path == "~" { return home }
        if path.hasPrefix("~/") { return (home == "/" ? "" : home) + path.dropFirst() }
        return path
    }

    public static func abbreviating(_ path: String, home: String) -> String {
        let home = PathScope.normalized(home)
        guard home.hasPrefix("/"), home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
