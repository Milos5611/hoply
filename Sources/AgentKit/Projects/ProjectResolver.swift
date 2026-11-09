import Foundation

public enum ProjectKind: String, Codable, Sendable, CaseIterable {
    case repo
    case folder
    case home
    case scratch
}

public struct ProjectResolution: Sendable, Equatable, Hashable {
    public var root: String
    public var name: String
    public var kind: ProjectKind
    /// The linked worktree's root when the cwd is inside one; the project is then its main repo.
    public var worktree: String?

    public init(root: String, name: String, kind: ProjectKind, worktree: String? = nil) {
        self.root = root
        self.name = name
        self.kind = kind
        self.worktree = worktree
    }
}

/// The filesystem reads the resolver needs. AgentSystem provides the real one; tests use a fake.
public protocol ProjectFileSystem {
    /// The absolute path with symlinks resolved, or nil if it does not exist.
    func realPath(_ path: String) -> String?
    func isDirectory(_ path: String) -> Bool
    func isFile(_ path: String) -> Bool
    func readText(_ path: String) -> String?
}

/// Maps a working directory to the project it belongs to, without running git.
public struct ProjectResolver: Sendable {
    public var home: String
    /// Directories whose descendants are Claude scratch workspaces; each of them groups into one project.
    public var scratchRoots: [String]

    public init(home: String, scratchRoots: [String]? = nil) {
        self.home = Self.standardize(home)
        self.scratchRoots = (scratchRoots ?? [home + "/Library/Application Support/Claude/scratch-workspaces"])
            .map(Self.standardize)
    }

    public func resolve(cwd: String, fileSystem fs: some ProjectFileSystem) -> ProjectResolution {
        let path = Self.standardize(fs.realPath(cwd) ?? cwd)
        let realHome = Self.standardize(fs.realPath(home) ?? home)

        for scratch in scratchRoots {
            let realScratch = Self.standardize(fs.realPath(scratch) ?? scratch)
            if path == realScratch || path.hasPrefix(realScratch + "/") {
                return ProjectResolution(root: realScratch, name: "Scratch", kind: .scratch)
            }
        }
        if path == realHome { return ProjectResolution(root: realHome, name: "Home", kind: .home) }

        // Walk up to (but not including) $HOME, so a dotfiles repo at ~/.git never swallows every folder.
        var directory = path
        while directory != "/" && directory != realHome && !directory.isEmpty {
            let gitPath = directory + "/.git"
            if fs.isDirectory(gitPath) {
                return ProjectResolution(root: directory, name: Self.lastComponent(directory), kind: .repo)
            }
            if fs.isFile(gitPath) {
                return linked(directory: directory, gitFile: gitPath, fs: fs)
            }
            directory = Self.parent(directory)
        }
        return ProjectResolution(root: path, name: Self.lastComponent(path), kind: .folder)
    }

    /// A `.git` file points at the real git dir. A linked worktree's git dir has a `commondir` file leading to
    /// the main repo's `.git`; a submodule's does not, so the submodule stays its own project.
    private func linked(directory: String, gitFile: String, fs: some ProjectFileSystem) -> ProjectResolution {
        let own = ProjectResolution(root: directory, name: Self.lastComponent(directory), kind: .repo)
        guard let text = fs.readText(gitFile),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else {
            return own
        }
        let gitdir = Self.absolute(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces),
                                   relativeTo: directory)
        guard let common = fs.readText(gitdir + "/commondir")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !common.isEmpty else {
            return own
        }
        let commonDir = Self.standardize(fs.realPath(Self.absolute(common, relativeTo: gitdir))
                                         ?? Self.absolute(common, relativeTo: gitdir))
        let mainRoot = Self.lastComponent(commonDir) == ".git" ? Self.parent(commonDir) : commonDir
        return ProjectResolution(root: mainRoot, name: Self.lastComponent(mainRoot), kind: .repo, worktree: directory)
    }

    static func absolute(_ path: String, relativeTo base: String) -> String {
        standardize(path.hasPrefix("/") ? path : base + "/" + path)
    }

    /// Collapses `.`/`..` and duplicate or trailing slashes without touching the filesystem.
    static func standardize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
