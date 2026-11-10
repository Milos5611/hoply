import Foundation

public struct ProcessIdentity: Hashable, Sendable {
    public var pid: Int32
    public var startedAt: Date

    public init(pid: Int32, startedAt: Date) {
        self.pid = pid
        self.startedAt = startedAt
    }

    public var startMicroseconds: Int64 {
        Int64((startedAt.timeIntervalSince1970 * 1_000_000).rounded())
    }
}

public struct ListeningSocket: Hashable, Sendable {
    public enum Family: String, Sendable {
        case ipv4
        case ipv6
    }

    public enum Reach: Sendable {
        case loopback
        case allInterfaces
        case address
    }

    public var port: Int
    public var family: Family
    public var address: String

    public init(port: Int, family: Family, address: String) {
        self.port = port
        self.family = family
        self.address = address
    }

    public var reach: Reach {
        if address == "0.0.0.0" || address == "::" { return .allInterfaces }
        if address == "::1" || address.hasPrefix("127.") || address.hasPrefix("::ffff:127.") { return .loopback }
        return .address
    }
}

public struct ScannedProcess: Sendable, Equatable, Identifiable {
    public var identity: ProcessIdentity
    public var parentPID: Int32
    public var groupID: Int32
    public var uid: UInt32
    public var name: String
    public var executable: String?
    public var arguments: [String]
    public var cwd: String?
    public var memoryBytes: UInt64?
    public var listeners: [ListeningSocket]

    public init(identity: ProcessIdentity, parentPID: Int32, groupID: Int32, uid: UInt32, name: String,
                executable: String? = nil, arguments: [String] = [], cwd: String? = nil, memoryBytes: UInt64? = nil,
                listeners: [ListeningSocket] = []) {
        self.identity = identity
        self.parentPID = parentPID
        self.groupID = groupID
        self.uid = uid
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.memoryBytes = memoryBytes
        self.listeners = listeners
    }

    public var id: ProcessIdentity { identity }
    public var pid: Int32 { identity.pid }
    public var isGroupLeader: Bool { identity.pid == groupID }
}

public struct ProcessSnapshot: Sendable, Equatable {
    public enum Source: String, Sendable {
        case libproc
        case lsof
        case unavailable
    }

    public var takenAt: Date
    public var source: Source
    public private(set) var processes: [ScannedProcess]
    private var indexByPID: [Int32: Int]

    public init(takenAt: Date = Date(), source: Source = .libproc, processes: [ScannedProcess]) {
        self.takenAt = takenAt
        self.source = source
        self.processes = processes
        indexByPID = Dictionary(processes.enumerated().map { ($1.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func process(_ pid: Int32) -> ScannedProcess? {
        indexByPID[pid].map { processes[$0] }
    }

    public func process(_ identity: ProcessIdentity) -> ScannedProcess? {
        process(identity.pid).flatMap { $0.identity == identity ? $0 : nil }
    }

    public var listening: [ScannedProcess] {
        processes.filter { !$0.listeners.isEmpty }
    }

    public func members(ofGroup groupID: Int32) -> [ScannedProcess] {
        processes.filter { $0.groupID == groupID }
    }
}

public enum ProcessArguments {
    public static func parse<Bytes: Collection>(procargs2 raw: Bytes) -> (executable: String, arguments: [String])?
    where Bytes.Element == UInt8 {
        let bytes = Array(raw)
        guard bytes.count > 4 else { return nil }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count >= 0 else { return nil }
        var index = 4

        func string() -> String? {
            guard index < bytes.count else { return nil }
            let end = bytes[index...].firstIndex(of: 0) ?? bytes.count
            defer { index = min(end + 1, bytes.count) }
            return String(decoding: bytes[index..<end], as: UTF8.self)
        }

        guard let executable = string() else { return nil }
        // The kernel pads the executable path with NULs up to a word boundary before argv[0].
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            guard let argument = string() else { break }
            arguments.append(argument)
        }
        return (executable, arguments)
    }
}

enum PathScope {
    static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func contains(_ root: String, _ path: String) -> Bool {
        let root = normalized(root)
        let path = normalized(path)
        guard !root.isEmpty, !path.isEmpty else { return false }
        return path == root || path.hasPrefix(root == "/" ? root : root + "/")
    }
}
