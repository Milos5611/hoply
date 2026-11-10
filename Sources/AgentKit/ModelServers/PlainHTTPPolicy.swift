import Foundation

public struct PlainHTTPPolicy: Sendable, Equatable {
    public var enforced: Bool
    public var allowsArbitraryLoads: Bool
    public var allowsLocalNetworking: Bool
    public var ranges: [IPv4Range]
    public var domains: [Domain]

    public struct IPv4Range: Sendable, Equatable {
        public var network: UInt32
        public var bits: Int

        public init?(_ text: String) {
            let parts = text.split(separator: "/")
            guard parts.count == 2, let address = PlainHTTPPolicy.ipv4(String(parts[0])), let bits = Int(parts[1]),
                  (0...32).contains(bits) else { return nil }
            self.bits = bits
            network = address & Self.mask(bits)
        }

        static func mask(_ bits: Int) -> UInt32 { bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits) }

        public func contains(_ address: UInt32) -> Bool { address & Self.mask(bits) == network }
    }

    public struct Domain: Sendable, Equatable {
        public var name: String
        public var includesSubdomains: Bool
    }

    public static let unenforced = PlainHTTPPolicy(enforced: false, allowsArbitraryLoads: true,
                                                   allowsLocalNetworking: true, ranges: [], domains: [])

    public init(enforced: Bool, allowsArbitraryLoads: Bool, allowsLocalNetworking: Bool, ranges: [IPv4Range],
                domains: [Domain]) {
        self.enforced = enforced
        self.allowsArbitraryLoads = allowsArbitraryLoads
        self.allowsLocalNetworking = allowsLocalNetworking
        self.ranges = ranges
        self.domains = domains
    }

    // A process with no Info.plist at all (a bare `swift build` binary, the test runner) isn't held to ATS.
    public init(infoDictionary: [String: Any]?) {
        guard let infoDictionary, !infoDictionary.isEmpty else {
            self = .unenforced
            return
        }
        let ats = infoDictionary["NSAppTransportSecurity"] as? [String: Any] ?? [:]
        var ranges: [IPv4Range] = []
        var domains: [Domain] = []
        for (key, value) in ats["NSExceptionDomains"] as? [String: Any] ?? [:] {
            guard let rules = value as? [String: Any], rules["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true else {
                continue
            }
            if let range = IPv4Range(key) {
                ranges.append(range)
            } else {
                domains.append(Domain(name: key.lowercased(), includesSubdomains: rules["NSIncludesSubdomains"] as? Bool == true))
            }
        }
        self.init(enforced: true, allowsArbitraryLoads: ats["NSAllowsArbitraryLoads"] as? Bool == true,
                  allowsLocalNetworking: ats["NSAllowsLocalNetworking"] as? Bool == true,
                  ranges: ranges, domains: domains.sorted { $0.name < $1.name })
    }

    public static var main: PlainHTTPPolicy { PlainHTTPPolicy(infoDictionary: Bundle.main.infoDictionary) }

    public func allows(_ raw: String) -> Bool {
        guard let sanitized = RemoteEndpoint.sanitizedBaseURL(raw), let url = URL(string: sanitized) else { return true }
        return allows(url)
    }

    public func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return true }
        guard enforced, !allowsArbitraryLoads else { return true }
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return true }
        if host.hasSuffix(".") { host.removeLast() }
        if domains.contains(where: { host == $0.name || ($0.includesSubdomains && host.hasSuffix("." + $0.name)) }) {
            return true
        }
        if let address = Self.ipv4(host) {
            if ranges.contains(where: { $0.contains(address) }) { return true }
            return allowsLocalNetworking && Self.localRanges.contains { $0.contains(address) }
        }
        if host.contains(":") {
            return allowsLocalNetworking && Self.isLocalIPv6(host)
        }
        if host == "localhost" { return true }
        return allowsLocalNetworking && (!host.contains(".") || host.hasSuffix(".local"))
    }

    // What NSAllowsLocalNetworking lets through on macOS 26, measured with a binary carrying this app's Info.plist:
    // loopback, RFC 1918, link-local, IPv6 unique-local, single-label and .local names. Not 100.64.0.0/10.
    static let localRanges = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"]
        .compactMap(IPv4Range.init)

    static func isLocalIPv6(_ host: String) -> Bool {
        let address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if address == "::1" { return true }
        guard let first = address.split(separator: ":", omittingEmptySubsequences: false).first,
              let group = UInt16(first, radix: 16) else { return false }
        return group & 0xFE00 == 0xFC00 || group & 0xFFC0 == 0xFE80
    }

    static func ipv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var address: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let octet = UInt8(part) else { return nil }
            address = address << 8 | UInt32(octet)
        }
        return address
    }
}
