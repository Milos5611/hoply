import Foundation

public struct RemoteRetry: Sendable, Equatable {
    public static let maxDelay: TimeInterval = 300

    public private(set) var failures = 0
    public private(set) var retryAt: Date?

    public init() {}

    public static func backoff(after failures: Int) -> TimeInterval {
        min(5 * pow(2, Double(min(max(failures, 1), 10) - 1)), maxDelay)
    }

    public func isWaiting(at now: Date) -> Bool {
        retryAt.map { now < $0 } ?? false
    }

    public mutating func failed(retryAfter: TimeInterval? = nil, now: Date) {
        failures += 1
        retryAt = now.addingTimeInterval(max(retryAfter ?? 0, Self.backoff(after: failures)))
    }

    public mutating func succeeded() {
        failures = 0
        retryAt = nil
    }
}

extension RemoteTranscriptPolicy {
    public static func pollInterval(openRequests: Int, watching: Bool, retry: RemoteRetry, now: Date) -> TimeInterval {
        watching && !retry.isWaiting(at: now)
            ? RemoteLinkPolicy.pollWhileOpen : RemoteLinkPolicy.pollInterval(openRequests: openRequests)
    }

    public static func wait(untilPoll: TimeInterval, watching: Bool, retry: RemoteRetry, now: Date) -> TimeInterval {
        guard watching else { return untilPoll }
        guard let retryAt = retry.retryAt, now < retryAt else { return min(untilPoll, refreshEvery) }
        return min(untilPoll, retryAt.timeIntervalSince(now))
    }
}
