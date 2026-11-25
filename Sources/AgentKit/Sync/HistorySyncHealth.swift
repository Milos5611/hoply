import Foundation

public enum HistorySyncOperation: String, CaseIterable, Sendable {
    case publish
    case fetch
}

public enum HistorySyncProblem: String, Sendable {
    case rejected
    case other
}

public struct HistorySyncFailure: Equatable, Sendable {
    public var operation: HistorySyncOperation
    public var problem: HistorySyncProblem
    public var since: Date
    public var last: Date

    public init(operation: HistorySyncOperation, problem: HistorySyncProblem, since: Date, last: Date) {
        self.operation = operation
        self.problem = problem
        self.since = since
        self.last = last
    }
}

public struct HistorySyncHealth: Equatable, Sendable {
    public private(set) var publish: HistorySyncFailure?
    public private(set) var fetch: HistorySyncFailure?

    public init() {}

    public var failure: HistorySyncFailure? {
        [publish, fetch].compactMap { $0 }.min { $0.since < $1.since }
    }

    public func failure(of operation: HistorySyncOperation) -> HistorySyncFailure? {
        switch operation {
        case .publish: publish
        case .fetch: fetch
        }
    }

    public mutating func succeeded(_ operation: HistorySyncOperation) {
        set(nil, for: operation)
    }

    @discardableResult
    public mutating func failed(_ operation: HistorySyncOperation, error: NSError, at now: Date) -> HistorySyncProblem? {
        guard let problem = Self.problem(for: error) else { return nil }
        set(HistorySyncFailure(operation: operation, problem: problem, since: failure(of: operation)?.since ?? now,
                               last: now), for: operation)
        return problem
    }

    private mutating func set(_ failure: HistorySyncFailure?, for operation: HistorySyncOperation) {
        switch operation {
        case .publish: publish = failure
        case .fetch: fetch = failure
        }
    }

    // Must say nil exactly where `CloudLinkError` maps a CKError to anything but `.other`: those the link shows or
    // retries as connectivity.
    public static func problem(for error: NSError) -> HistorySyncProblem? {
        if error.domain == NSURLErrorDomain { return nil }
        guard error.domain == CloudKitError.domain else { return .other }
        if error.code == CloudKitError.partialFailure {
            let problems = causes(of: error).map(problem(for:))
            if problems.contains(nil) { return nil }
            return problems.contains(.rejected) ? .rejected : .other
        }
        if CloudKitError.neverCounted.contains(error.code) { return nil }
        return CloudKitError.rejected.contains(error.code) ? .rejected : .other
    }

    public static func causes(of error: NSError) -> [NSError] {
        guard error.domain == CloudKitError.domain, error.code == CloudKitError.partialFailure,
              let items = error.userInfo[CloudKitError.partialErrorsKey] as? [AnyHashable: Any] else { return [] }
        return items.values.compactMap { $0 as? NSError }
            .filter { !($0.domain == CloudKitError.domain && $0.code == CloudKitError.batchRequestFailed) }
            .sorted { ($0.domain, $0.code) < ($1.domain, $1.code) }
    }
}

// CKError.Code raw values; AgentKit doesn't link CloudKit.
private enum CloudKitError {
    static let domain = "CKErrorDomain"
    static let partialErrorsKey = "CKPartialErrors"
    static let partialFailure = 2
    static let batchRequestFailed = 22
    static let rejected: Set<Int> = [
        10, // permissionFailure
        11, // unknownItem
        12, // invalidArguments
        15, // serverRejectedRequest
    ]
    static let neverCounted: Set<Int> = [
        3, 4, 34, // networkUnavailable, networkFailure, serverResponseLost
        5, 8, // badContainer, missingEntitlement
        6, 7, 23, // serviceUnavailable, requestRateLimited, zoneBusy
        9, 32, 36, // notAuthenticated, managedAccountRestricted, accountTemporarilyUnavailable
        25, // quotaExceeded
    ]
}
