import Foundation

/// The monthly premium-request allowance. GitHub resets the counters on the 1st of each month at 00:00 UTC,
/// whatever the user's time zone.
public struct CopilotAllowance: Sendable, Equatable {
    public var used: Double
    /// 0 means not set: no remaining, fraction or overage.
    public var allowance: Int
    public var usdPerExtraRequest: Double
    /// The UTC month containing `now`; feed it to `StoreReader.totalsBySource(in:)` for `used`.
    public var month: DateInterval

    public init(used: Double, allowance: Int, usdPerExtraRequest: Double, now: Date = Date()) {
        self.used = max(used, 0)
        self.allowance = max(allowance, 0)
        self.usdPerExtraRequest = max(usdPerExtraRequest, 0)
        self.month = Self.month(containing: now)
    }

    public init(used: Double, settings: AppSettings, now: Date = Date()) {
        self.init(used: used, allowance: settings.copilotMonthlyAllowance,
                  usdPerExtraRequest: settings.copilotUSDPerPremiumRequest, now: now)
    }

    public var isSet: Bool { allowance > 0 }
    public var nextReset: Date { month.end }

    public var remaining: Double? {
        isSet ? max(Double(allowance) - used, 0) : nil
    }

    /// `used / allowance`; above 1 once the allowance is spent.
    public var fraction: Double? {
        isSet ? used / Double(allowance) : nil
    }

    public var overageRequests: Double? {
        isSet ? max(used - Double(allowance), 0) : nil
    }

    public var overageUSD: Double? {
        overageRequests.map { $0 * usdPerExtraRequest }
    }

    public static func month(containing date: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? date
        return DateInterval(start: start, end: end)
    }
}
