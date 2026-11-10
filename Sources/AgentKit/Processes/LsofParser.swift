import Foundation

public enum LsofParser {
    public struct Entry: Sendable, Equatable {
        public var pid: Int32
        public var parentPID: Int32?
        public var groupID: Int32?
        public var uid: UInt32?
        public var command: String
        public var listeners: [ListeningSocket]

        public init(pid: Int32, parentPID: Int32? = nil, groupID: Int32? = nil, uid: UInt32? = nil,
                    command: String = "", listeners: [ListeningSocket] = []) {
            self.pid = pid
            self.parentPID = parentPID
            self.groupID = groupID
            self.uid = uid
            self.command = command
            self.listeners = listeners
        }
    }

    private struct File {
        var type: String?
        var proto: String?
        var name: String?
        var state: String?
    }

    public static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var current: Entry?
        var file: File?

        func closeFile() {
            guard let open = file, let listener = listener(open), current != nil else { file = nil; return }
            if current?.listeners.contains(listener) == false { current?.listeners.append(listener) }
            file = nil
        }
        func closeProcess() {
            closeFile()
            if let entry = current, !entry.listeners.isEmpty { entries.append(entry) }
            current = nil
        }

        for line in text.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                closeProcess()
                current = Int32(value).map { Entry(pid: $0) }
            case "f":
                closeFile()
                file = File()
            case "R": current?.parentPID = Int32(value)
            case "g": current?.groupID = Int32(value)
            case "u": current?.uid = UInt32(value)
            case "c": current?.command = value
            case "t": file?.type = value
            case "P": file?.proto = value
            case "n": file?.name = value
            case "T":
                if value.hasPrefix("ST=") { file?.state = String(value.dropFirst(3)) }
            default: continue
            }
        }
        closeProcess()
        return entries
    }

    public static func listener(type: String?, name: String) -> ListeningSocket? {
        guard !name.contains("->"), let colon = name.lastIndex(of: ":"),
              let port = Int(name[name.index(after: colon)...]), (1...65_535).contains(port) else { return nil }
        var host = String(name[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let family: ListeningSocket.Family
        switch type {
        case "IPv4": family = .ipv4
        case "IPv6": family = .ipv6
        default: family = host.contains(":") ? .ipv6 : .ipv4
        }
        if host == "*" || host.isEmpty { host = family == .ipv6 ? "::" : "0.0.0.0" }
        return ListeningSocket(port: port, family: family, address: host)
    }

    private static func listener(_ file: File) -> ListeningSocket? {
        guard let name = file.name, file.proto ?? "TCP" == "TCP", file.state ?? "LISTEN" == "LISTEN" else { return nil }
        return listener(type: file.type, name: name)
    }
}
