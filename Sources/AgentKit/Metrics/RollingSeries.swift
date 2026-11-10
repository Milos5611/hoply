import Foundation

public struct RollingSeries: Equatable, Sendable {
    public let bucketLength: TimeInterval
    public private(set) var values: [Double]
    private var currentStart: Date

    public init(bucketLength: TimeInterval, capacity: Int, now: Date) {
        precondition(bucketLength > 0 && capacity > 0)
        self.bucketLength = bucketLength
        self.values = Array(repeating: 0, count: capacity)
        self.currentStart = now
    }

    public mutating func add(_ amount: Double = 1, at time: Date) {
        guard let index = index(for: time) else { return }
        values[index] += amount
    }

    public mutating func recordMax(_ value: Double, at time: Date) {
        guard let index = index(for: time) else { return }
        values[index] = max(values[index], value)
    }

    public mutating func advance(to time: Date) {
        let elapsed = Int((time.timeIntervalSince(currentStart) / bucketLength).rounded(.down))
        guard elapsed > 0 else { return }
        let shift = min(elapsed, values.count)
        values.removeFirst(shift)
        values.append(contentsOf: repeatElement(0, count: shift))
        currentStart += Double(elapsed) * bucketLength
    }

    private mutating func index(for time: Date) -> Int? {
        advance(to: time)
        guard time < currentStart else { return values.count - 1 }
        let back = Int((currentStart.timeIntervalSince(time) / bucketLength).rounded(.up))
        let index = values.count - 1 - back
        return index >= 0 ? index : nil
    }
}
