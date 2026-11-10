import Foundation

public struct DirectorySizer: Sendable {
    public init() {}

    public func allocatedSize(of path: String) -> Int64? {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        let root = URL(fileURLWithPath: path)
        guard let values = try? root.resourceValues(forKeys: keys) else { return nil }
        if values.isRegularFile == true { return Int64(values.totalFileAllocatedSize ?? 0) }
        // The enumerator lists a symlink as an entry and never walks through it.
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                           options: [], errorHandler: { _, _ in true }) else { return nil }
        var total: Int64 = 0
        var visited = 0
        for case let entry as URL in entries {
            visited += 1
            if visited.isMultiple(of: 512), Task.isCancelled { return nil }
            guard let values = try? entry.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
