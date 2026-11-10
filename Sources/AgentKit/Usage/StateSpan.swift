import Foundation

public struct StateSpan: Sendable, Equatable {
    public var state: SessionState
    public var start: Date
    public var end: Date?

    public init(state: SessionState, start: Date, end: Date? = nil) {
        self.state = state
        self.start = start
        self.end = end
    }

    public var isOpen: Bool { end == nil }

    public func duration(now: Date) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }

    public static func coalesced(_ spans: [StateSpan], gap: TimeInterval = 1) -> [StateSpan] {
        var result: [StateSpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.state == span.state, let end = last.end,
               span.start.timeIntervalSince(end) <= gap {
                result[result.count - 1].end = span.end.map { max($0, end) }
            } else {
                result.append(span)
            }
        }
        return result
    }

    public static func timeInState(_ spans: [StateSpan], now: Date) -> [SessionState: TimeInterval] {
        var totals: [SessionState: TimeInterval] = [:]
        for span in spans { totals[span.state, default: 0] += span.duration(now: now) }
        return totals
    }
}
