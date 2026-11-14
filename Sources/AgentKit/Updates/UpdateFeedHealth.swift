import Foundation

public enum UpdateFeedProblem: String, Codable, Sendable {
    case unavailable
    case unreadable
    case badSignature
    case misconfigured
}

public struct UpdateFeedFailure: Codable, Equatable, Sendable {
    public var problem: UpdateFeedProblem
    public var since: Date
    public var last: Date
    public var detail: String

    public init(problem: UpdateFeedProblem, since: Date, last: Date, detail: String) {
        self.problem = problem
        self.since = since
        self.last = last
        self.detail = detail
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        problem = try container.decode(UpdateFeedProblem.self, forKey: .problem)
        since = try container.decode(Date.self, forKey: .since)
        last = container.lenient(Date.self, .last) ?? since
        detail = container.lenient(String.self, .detail) ?? ""
    }

    public static func decoded(_ data: Data?) -> UpdateFeedFailure? {
        data.flatMap { try? JSONDecoder().decode(UpdateFeedFailure.self, from: $0) }
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

public struct UpdateFeedHealth: Equatable, Sendable {
    public private(set) var failure: UpdateFeedFailure?
    private var feedLoaded = false

    public init(failure: UpdateFeedFailure? = nil) {
        self.failure = failure
    }

    public mutating func appcastLoaded(verified: Bool) {
        guard verified else { return }
        feedLoaded = true
        failure = nil
    }

    // Once the feed has loaded, later errors in the same cycle come from the archive download or install.
    public mutating func checkFailed(_ error: NSError, at now: Date) {
        guard !feedLoaded, let problem = Self.problem(for: error) else { return }
        failure = UpdateFeedFailure(problem: problem, since: failure?.since ?? now, last: now,
                                    detail: Self.causes(of: error).last?.localizedDescription ?? "")
    }

    public mutating func cycleEnded() {
        feedLoaded = false
    }

    public static func problem(for error: NSError) -> UpdateFeedProblem? {
        guard error.domain == SparkleError.domain else { return nil }
        let causes = Self.causes(of: error).dropFirst()
        switch error.code {
        case SparkleError.configuration:
            return .misconfigured
        case SparkleError.appcastParse:
            return causes.contains { $0.domain == SparkleError.domain && $0.code == SparkleError.validation }
                ? .badSignature : .unreadable
        case SparkleError.appcast:
            return .unreadable
        case SparkleError.download:
            // Sparkle's own HTTP status check is the only cause without a URLSession error underneath.
            if causes.allSatisfy({ $0.domain == SparkleError.domain }) { return .unavailable }
            return causes.contains { $0.domain == NSURLErrorDomain && Self.brokenRedirects.contains($0.code) }
                ? .unavailable : nil
        default:
            return nil
        }
    }

    private static let brokenRedirects: Set<Int> = [
        URLError.Code.httpTooManyRedirects.rawValue, URLError.Code.redirectToNonExistentLocation.rawValue,
    ]

    private static func causes(of error: NSError) -> [NSError] {
        var chain = [error]
        while chain.count < 8, let next = chain.last?.userInfo[NSUnderlyingErrorKey] as? NSError {
            chain.append(next)
        }
        return chain
    }
}

// SUErrors.h in Sparkle 2.10.1; AgentKit doesn't link Sparkle.
private enum SparkleError {
    static let domain = "SUSparkleErrorDomain"
    static let configuration = 1...7
    static let appcastParse = 1000
    static let appcast = 1002
    static let download = 2001
    static let validation = 3002
}
