import AgentKit
import Darwin
import Foundation

public struct CleanupFiles: Sendable {
    private let paths = LocalProjectFileSystem()

    public init() {}

    public func canonical(_ path: String) -> String {
        paths.realPath(path) ?? path
    }

    public func isDirectory(_ path: String) -> Bool {
        info(path).map { $0.st_mode & S_IFMT == S_IFDIR } ?? false
    }

    public func exists(_ path: String) -> Bool {
        info(path) != nil
    }

    public func modified(_ path: String) -> Date? {
        info(path).map {
            Date(timeIntervalSince1970: TimeInterval($0.st_mtimespec.tv_sec) + TimeInterval($0.st_mtimespec.tv_nsec) / 1e9)
        }
    }

    public func entries(of directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
    }

    public func transcriptFiles(under directory: String) -> [String] {
        guard let entries = FileManager.default.enumerator(atPath: directory) else { return [] }
        return entries.compactMap { $0 as? String }.filter { $0.hasSuffix(".jsonl") }.map { directory + "/" + $0 }.sorted()
    }

    // lstat: a symlinked directory is neither walked nor measured as the folder it points to.
    private func info(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }
}
