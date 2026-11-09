import AgentKit
import Darwin
import Foundation

/// Where reading of a file stopped. `size` is the file size when a read reached the end (the coordinator
/// stores `offset` instead while a file is only partly read), so a stat-only rescan can tell whether anything
/// is unread without opening the file.
public struct FileCursor: Sendable, Equatable {
    public var inode: UInt64
    public var size: Int64
    public var offset: Int64
    /// FNV-1a of the first `min(512, offset)` bytes; a mismatch means the file was rewritten in place.
    public var headHash: UInt64

    public init(inode: UInt64, size: Int64, offset: Int64, headHash: UInt64) {
        self.inode = inode
        self.size = size
        self.offset = offset
        self.headHash = headHash
    }
}

public struct FileStat: Sendable, Equatable {
    public var inode: UInt64
    public var size: Int64
    public var modified: Date
}

public struct TailChunk: Sendable {
    public var lines: [Data]
    /// File offset of the first line; 0 after a reset.
    public var startOffset: Int64
    public var cursor: FileCursor
    /// The file was replaced, truncated or rewritten, so reading restarted at 0.
    public var didReset: Bool
    /// Everything up to the size seen at open was read (a trailing partial line may remain).
    public var atEnd: Bool
    public var bytesConsumed: Int64
}

/// Reads only complete lines past a cursor. Re-reads from 0 when the inode changes, the file shrinks below
/// the cursor, or its first bytes changed; the ledger's upserts make re-reading harmless.
public enum FileTailer {
    public static let headLength: Int64 = 512

    public static func status(of path: String) -> FileStat? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileStat(inode: UInt64(info.st_ino), size: Int64(info.st_size),
                        modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                                       + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9))
    }

    /// Nil when the file does not exist. Reads at most about `maxBytes`, more only to finish one long line.
    public static func read(path: String, from cursor: FileCursor?, maxBytes: Int = 4 << 20) throws -> TailChunk? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let inode = UInt64(info.st_ino)
        let size = Int64(info.st_size)

        var offset = cursor?.offset ?? 0
        var didReset = false
        if let cursor {
            if cursor.inode != inode || size < cursor.offset {
                didReset = true
            } else if cursor.offset > 0 {
                let head = try readBytes(fd, at: 0, count: Int(min(headLength, cursor.offset)))
                if FNV1a.hash64(head) != cursor.headHash { didReset = true }
            }
        }
        if didReset { offset = 0 }

        let available = size - offset
        var wanted = Int(min(Int64(maxBytes), available))
        var data = try readBytes(fd, at: offset, count: wanted)
        var split = JSONLines.complete(in: data)
        while split.consumed == 0, Int64(data.count) < available {
            wanted = Int(min(Int64(wanted) * 2, available))
            data = try readBytes(fd, at: offset, count: wanted)
            split = JSONLines.complete(in: data)
        }

        let newOffset = offset + Int64(split.consumed)
        let head = try readBytes(fd, at: 0, count: Int(min(headLength, newOffset)))
        return TailChunk(lines: split.lines, startOffset: offset,
                         cursor: FileCursor(inode: inode, size: size, offset: newOffset, headHash: FNV1a.hash64(head)),
                         didReset: didReset, atEnd: offset + Int64(data.count) >= size,
                         bytesConsumed: Int64(split.consumed))
    }

    private static func readBytes(_ fd: Int32, at offset: Int64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var filled = 0
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while filled < count {
                let result = pread(fd, base + filled, count - filled, off_t(offset) + off_t(filled))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if result == 0 { break }
                filled += result
            }
        }
        if filled < count { data.removeSubrange(filled...) }
        return data
    }
}
