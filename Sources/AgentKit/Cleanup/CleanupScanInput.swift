import Foundation

public struct CleanupActivity: Sendable, Equatable {
    public var sessionDirectories: [String]
    public var devServerDirectories: [String]

    public init(sessionDirectories: [String] = [], devServerDirectories: [String] = []) {
        self.sessionDirectories = sessionDirectories
        self.devServerDirectories = devServerDirectories
    }

    public func hasSession(inside roots: [String]) -> Bool {
        Self.any(sessionDirectories, inside: roots)
    }

    public func hasDevServer(inside roots: [String]) -> Bool {
        Self.any(devServerDirectories, inside: roots)
    }

    public func mapped(_ transform: (String) -> String) -> CleanupActivity {
        CleanupActivity(sessionDirectories: sessionDirectories.map(transform),
                        devServerDirectories: devServerDirectories.map(transform))
    }

    private static func any(_ directories: [String], inside roots: [String]) -> Bool {
        directories.contains { directory in roots.contains { PathScope.contains($0, directory) } }
    }
}

public struct CleanupOptions: Sendable, Equatable {
    public var thresholds: CleanupRules.Thresholds
    public var includesProtectedFolders: Bool

    public init(thresholds: CleanupRules.Thresholds = CleanupRules.Thresholds(), includesProtectedFolders: Bool = false) {
        self.thresholds = thresholds
        self.includesProtectedFolders = includesProtectedFolders
    }
}
