import CryptoKit
import Foundation

public struct RemoteHistoryPartKey: Hashable, Sendable, Comparable {
    public var device: String
    public var day: String
    public var part: Int

    public init(device: String, day: String, part: Int) {
        self.device = device
        self.day = day
        self.part = part
    }

    public var recordName: String { RemoteSchema.historyRecordName(device: device, day: day, part: part) }

    public static func < (lhs: RemoteHistoryPartKey, rhs: RemoteHistoryPartKey) -> Bool {
        (lhs.device, lhs.day, lhs.part) < (rhs.device, rhs.day, rhs.part)
    }
}

public struct RemoteHistoryDay: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public enum ProjectKind: String, Codable, Sendable {
        case repo
        case folder
        case home
        case scratch
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        public init(_ kind: AgentKit.ProjectKind) {
            self = Self(rawValue: kind.rawValue) ?? .unknown
        }

        public var local: AgentKit.ProjectKind { AgentKit.ProjectKind(rawValue: rawValue) ?? .folder }
    }

    public struct Project: Codable, Sendable, Equatable, Hashable {
        public var id: String
        public var name: String
        public var title: String?
        public var origin: String?
        public var kind: ProjectKind

        public init(id: String, name: String, title: String? = nil, origin: String? = nil, kind: ProjectKind) {
            self.id = id
            self.name = name
            self.title = title
            self.origin = origin
            self.kind = kind
        }

        public static func id(root: String) -> String { RemoteSchema.sessionHash(root) }
    }

    public struct Usage: Codable, Sendable, Equatable {
        public var model: String?
        public var speed: String?
        public var project: String?
        public var at: Date
        public var last: Date
        public var prompt: Int
        public var tokens: TokenCounts
        public var calls: Int
        public var nativeUSD: Double?
        public var nativeCost: Double?
        public var premium: Double?

        public init(model: String?, speed: String? = nil, project: String? = nil, at: Date, last: Date,
                    prompt: Int = 0, tokens: TokenCounts, calls: Int, nativeUSD: Double? = nil,
                    nativeCost: Double? = nil, premium: Double? = nil) {
            self.model = model
            self.speed = speed
            self.project = project
            self.at = at
            self.last = last
            self.prompt = prompt
            self.tokens = tokens
            self.calls = calls
            self.nativeUSD = nativeUSD
            self.nativeCost = nativeCost
            self.premium = premium
        }

        var order: (Double, String, String, String, Int) {
            (at.timeIntervalSince1970, model ?? "", speed ?? "", project ?? "", prompt)
        }
    }

    public struct Session: Codable, Sendable, Equatable {
        public var key: String
        public var agent: String
        public var project: String?
        public var title: String?
        public var start: Date
        public var end: Date
        public var usage: [Usage]

        public init(key: String, agent: String, project: String? = nil, title: String? = nil, start: Date,
                    end: Date, usage: [Usage]) {
            self.key = key
            self.agent = agent
            self.project = project
            self.title = title
            self.start = start
            self.end = end
            self.usage = usage
        }

        public var source: AgentSource? { AgentSource(rawValue: agent) }
        public var sessionKey: SessionKey? { RemoteSchema.sessionKey(from: key) }
    }

    public var version: Int
    public var device: String
    public var deviceName: String?
    public var machine: String?
    public var day: String
    public var part: Int
    public var parts: Int
    public var updatedAt: Date
    public var projects: [Project]
    public var sessions: [Session]

    public init(version: Int = RemoteHistoryDay.currentVersion, device: String, deviceName: String? = nil,
                machine: String? = nil, day: String, part: Int = 0, parts: Int = 1, updatedAt: Date,
                projects: [Project] = [], sessions: [Session] = []) {
        self.version = version
        self.device = device
        self.deviceName = deviceName
        self.machine = machine
        self.day = day
        self.part = part
        self.parts = parts
        self.updatedAt = updatedAt
        self.projects = projects
        self.sessions = sessions
    }

    public var key: RemoteHistoryPartKey { RemoteHistoryPartKey(device: device, day: day, part: part) }
}

public enum RemoteMachine {
    // The prefix keeps the hash useless outside Hoply; the hardware id itself never leaves the Mac.
    public static func fingerprint(hardwareID: String) -> String? {
        let id = hardwareID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !id.isEmpty else { return nil }
        return SHA256.hash(data: Data(("hoply-machine-v1:" + id).utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }
}

// Days are UTC, so every Mac files a call under the same day whatever its time zone.
public enum RemoteHistoryCalendar {
    public static func day(of date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    public static func start(of day: Int) -> Date { Date(timeIntervalSince1970: Double(day) * 86_400) }

    public static func interval(of day: Int) -> DateInterval {
        DateInterval(start: start(of: day), duration: 86_400)
    }

    public static func name(of day: Int) -> String {
        let z = day + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        func pad(_ value: Int, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(width - text.count, 0)) + text
        }
        return "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))"
    }

    public static func day(named name: String) -> Int? {
        let fields = name.split(separator: "-")
        guard fields.count == 3, fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              let y0 = Int(fields[0]), let m = Int(fields[1]), let d = Int(fields[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let day = era * 146_097 + doe - 719_468
        return self.name(of: day) == name ? day : nil
    }
}

extension RemoteHistoryDay {
    public static func build(device: String, deviceName: String?, machine: String? = nil, day: Int,
                             sessions: [Session], projects: [Project], updatedAt: Date,
                             byteLimit: Int = RemoteHistoryPolicy.byteLimit) -> [RemoteHistoryDay] {
        let name = RemoteHistoryCalendar.name(of: day)
        let bounds = RemoteHistoryCalendar.interval(of: day)
        let cleaned = sessions.compactMap { session -> Session? in
            let usage = session.usage.filter { $0.calls > 0 }.sorted { $0.order < $1.order }
            guard let first = usage.first else { return nil }
            var copy = session
            copy.usage = usage
            copy.title = RemoteSchema.title(session.title.flatMap { $0.isEmpty ? nil : $0 })
            let start = usage.map(\.at).min() ?? first.at
            let end = usage.map(\.last).max() ?? first.last
            copy.start = bounds.contains(session.start) ? min(session.start, start) : start
            copy.end = bounds.contains(session.end) && session.end < bounds.end ? max(session.end, end) : end
            return copy
        }
        .sorted { $0.key < $1.key }
        let catalog = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let envelope = RemoteHistoryDay(device: device, deviceName: deviceName, machine: machine, day: name,
                                        part: 999_999, parts: 999_999, updatedAt: updatedAt)
        let budget = byteLimit - (encodedSize(envelope) ?? 512)

        func referenced(_ session: Session) -> [Project] {
            Set([session.project] + session.usage.map(\.project)).compactMap { $0 }.compactMap { catalog[$0] }
        }
        func size(_ session: Session) -> Int {
            (encodedSize(session) ?? budget) + 1 + referenced(session).reduce(0) { $0 + (encodedSize($1) ?? 0) + 1 }
        }

        var units: [(session: Session, size: Int)] = []
        for session in cleaned {
            let whole = size(session)
            guard whole > budget else {
                units.append((session, whole))
                continue
            }
            var chunk = session
            chunk.usage = []
            for usage in session.usage {
                var next = chunk
                next.usage.append(usage)
                if !chunk.usage.isEmpty, size(next) > budget {
                    units.append((chunk, size(chunk)))
                    next = session
                    next.usage = [usage]
                }
                chunk = next
            }
            if !chunk.usage.isEmpty { units.append((chunk, size(chunk))) }
        }

        var groups: [[Session]] = []
        var current: [Session] = []
        var used = 0
        for unit in units {
            if !current.isEmpty, used + unit.size > budget {
                groups.append(current)
                current = []
                used = 0
            }
            current.append(unit.session)
            used += unit.size
        }
        if !current.isEmpty || groups.isEmpty { groups.append(current) }

        return groups.enumerated().map { index, group in
            let ids = Set(group.flatMap { [$0.project] + $0.usage.map(\.project) }.compactMap { $0 })
            return RemoteHistoryDay(device: device, deviceName: deviceName, machine: machine, day: name, part: index,
                                    parts: groups.count, updatedAt: updatedAt,
                                    projects: ids.sorted().compactMap { catalog[$0] }, sessions: group)
        }
    }

    // The build time and the Mac's name are left out, so an unchanged day is never uploaded again.
    public static func fingerprint(_ parts: [RemoteHistoryDay]) -> String {
        let content = parts.map { part -> RemoteHistoryDay in
            var copy = part
            copy.updatedAt = Date(timeIntervalSince1970: 0)
            copy.deviceName = nil
            return copy
        }
        return FNV1a.hex64((try? RemoteSchema.encode(content)) ?? Data())
    }

    static func encodedSize<T: Encodable>(_ value: T) -> Int? {
        (try? RemoteSchema.encode(value))?.count
    }
}
