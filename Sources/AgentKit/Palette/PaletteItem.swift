import Foundation

public struct PaletteItem: Identifiable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case session
        case project
        case devServer
        case page
        case action

        var order: Int {
            switch self {
            case .session: return 0
            case .devServer: return 1
            case .project: return 2
            case .page: return 3
            case .action: return 4
            }
        }
    }

    public enum Attention: Int, Comparable, Sendable {
        case none
        case live
        case needsUser

        public static func < (lhs: Attention, rhs: Attention) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var keywords: [String]
    public var lastActive: Date?
    public var attention: Attention

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, keywords: [String] = [],
                lastActive: Date? = nil, attention: Attention = .none) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.lastActive = lastActive
        self.attention = attention
    }

    public static func sessionID(_ key: SessionKey) -> String { "session:\(key.source.rawValue):\(key.id)" }
    public static func projectID(_ id: Int64) -> String { "project:\(id)" }
    public static func devServerID(_ id: String) -> String { "devserver:\(id)" }
    public static func pageID(_ rawValue: String) -> String { "page:\(rawValue)" }
    public static func actionID(_ name: String) -> String { "action:\(name)" }

    public static func sessionKey(fromID id: String) -> SessionKey? {
        guard let rest = payload(of: id, prefix: "session:"), let colon = rest.firstIndex(of: ":"),
              let source = AgentSource(rawValue: String(rest[..<colon])) else { return nil }
        let sessionID = String(rest[rest.index(after: colon)...])
        return sessionID.isEmpty ? nil : SessionKey(source: source, id: sessionID)
    }

    public static func projectID(fromID id: String) -> Int64? {
        payload(of: id, prefix: "project:").flatMap { Int64($0) }
    }

    public static func payload(of id: String, prefix: String) -> Substring? {
        id.hasPrefix(prefix) ? id.dropFirst(prefix.count) : nil
    }
}
