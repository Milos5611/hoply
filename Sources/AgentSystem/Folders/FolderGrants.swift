import AgentKit
import Foundation
import os

public protocol FolderBookmarks: Sendable {
    func create(for url: URL, readOnly: Bool) throws -> Data
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

public struct SecurityScopedBookmarks: FolderBookmarks {
    public init() {}

    public func create(for url: URL, readOnly: Bool) throws -> Data {
        try url.bookmarkData(options: readOnly ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
                                               : [.withSecurityScope],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

public final class FolderGrants: Sendable {
    public static let defaultsKey = "HoplyFolderGrants"
    public static let shared = FolderGrants()

    struct Saved: Codable, Equatable {
        var bookmark: Data
        var path: String
        var readOnly: Bool
    }

    private struct State {
        var activated = false
        var saved: [AgentFolder: Saved] = [:]
        var grants: [AgentFolder: FolderGrant] = [:]
        var accessed: [AgentFolder: URL] = [:]
        var failures: [AgentFolder: String] = [:]
    }

    public let edition: Edition
    private let bookmarks: any FolderBookmarks
    private let load: @Sendable () -> Data?
    private let store: @Sendable (Data?) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(edition: Edition = .current, bookmarks: any FolderBookmarks = SecurityScopedBookmarks(),
                load: @escaping @Sendable () -> Data?, store: @escaping @Sendable (Data?) -> Void) {
        self.edition = edition
        self.bookmarks = bookmarks
        self.load = load
        self.store = store
    }

    public convenience init(edition: Edition = .current, bookmarks: any FolderBookmarks = SecurityScopedBookmarks(),
                            defaultsKey key: String = FolderGrants.defaultsKey) {
        self.init(edition: edition, bookmarks: bookmarks,
                  load: { UserDefaults.standard.data(forKey: key) },
                  store: { data in UserDefaults.standard.set(data, forKey: key) })
    }

    deinit {
        let accessed = state.withLock { $0.accessed }
        for url in accessed.values { bookmarks.stopAccessing(url) }
    }

    public func activate() {
        guard edition.needsFolderGrants else { return }
        state.withLock { state in
            guard !state.activated else { return }
            state.activated = true
            state.saved = Self.decode(load())
            var refreshed = false
            for (folder, saved) in state.saved {
                do {
                    let (url, isStale) = try bookmarks.resolve(saved.bookmark)
                    guard bookmarks.startAccessing(url) else {
                        state.failures[folder] = "macOS refused access to \(UserHome.abbreviating(url.path))"
                        continue
                    }
                    state.accessed[folder] = url
                    let path = Self.canonical(url.path)
                    state.grants[folder] = FolderGrant(folder: folder, path: path, readOnly: saved.readOnly)
                    if isStale, let fresh = try? bookmarks.create(for: url, readOnly: saved.readOnly) {
                        state.saved[folder] = Saved(bookmark: fresh, path: path, readOnly: saved.readOnly)
                        refreshed = true
                    } else if path != saved.path {
                        state.saved[folder]?.path = path
                        refreshed = true
                    }
                } catch {
                    state.failures[folder] = "\(UserHome.abbreviating(saved.path)) can't be found any more"
                }
            }
            if refreshed { persist(state.saved) }
        }
    }

    @discardableResult
    public func grant(_ url: URL, for folder: AgentFolder) throws -> FolderGrant {
        activate()
        let data = try bookmarks.create(for: url, readOnly: false)
        let (resolved, _) = try bookmarks.resolve(data)
        let started = bookmarks.startAccessing(resolved)
        let path = Self.canonical(resolved.path)
        let grant = FolderGrant(folder: folder, path: path, readOnly: false)
        let previous = state.withLock { state -> URL? in
            let previous = state.accessed[folder]
            state.accessed[folder] = started ? resolved : nil
            state.saved[folder] = Saved(bookmark: data, path: path, readOnly: false)
            state.grants[folder] = grant
            state.failures[folder] = nil
            persist(state.saved)
            return previous
        }
        if let previous { bookmarks.stopAccessing(previous) }
        return grant
    }

    public func revoke(_ folder: AgentFolder) {
        let previous = state.withLock { state -> URL? in
            let previous = state.accessed.removeValue(forKey: folder)
            state.saved[folder] = nil
            state.grants[folder] = nil
            state.failures[folder] = nil
            persist(state.saved)
            return previous
        }
        if let previous { bookmarks.stopAccessing(previous) }
    }

    public var grants: [FolderGrant] {
        activate()
        return state.withLock { state in AgentFolder.allCases.compactMap { state.grants[$0] } }
    }

    public func access(for folder: AgentFolder, at path: String) -> FolderAccess {
        guard edition.needsFolderGrants else { return .notNeeded }
        activate()
        let canonical = Self.canonical(path)
        let exists = FileManager.default.fileExists(atPath: canonical)
        let (grants, failures) = state.withLock { state in
            (AgentFolder.allCases.compactMap { state.grants[$0] }, state.failures)
        }
        return FolderGrantRules.access(for: folder, at: canonical, exists: exists, edition: edition, grants: grants,
                                       failures: failures)
    }

    public func access(settings: AppSettings,
                       environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: String = UserHome.path) -> [AgentFolder: FolderAccess] {
        Dictionary(uniqueKeysWithValues: AgentFolder.allCases.map { folder in
            (folder, access(for: folder, at: folder.path(settings: settings, environment: environment, home: home)))
        })
    }

    private func persist(_ saved: [AgentFolder: Saved]) {
        let keyed = Dictionary(uniqueKeysWithValues: saved.map { ($0.key.rawValue, $0.value) })
        store(keyed.isEmpty ? nil : try? JSONEncoder().encode(keyed))
    }

    static func decode(_ data: Data?) -> [AgentFolder: Saved] {
        guard let data, let keyed = try? JSONDecoder().decode([String: Saved].self, from: data) else { return [:] }
        var saved: [AgentFolder: Saved] = [:]
        for (key, value) in keyed {
            if let folder = AgentFolder(rawValue: key) { saved[folder] = value }
        }
        return saved
    }

    // A folder Connect has yet to create still has to compare against grants made on its resolved parent.
    static func canonical(_ path: String) -> String {
        let fileSystem = LocalProjectFileSystem()
        var existing = URL(fileURLWithPath: path).standardizedFileURL.path
        var missing: [String] = []
        while existing != "/" {
            if let real = fileSystem.realPath(existing) {
                return missing.reversed().reduce(real) { ($0 as NSString).appendingPathComponent($1) }
            }
            missing.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
