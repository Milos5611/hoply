import Foundation
import IOKit.pwr_mgt

public final class KeepAwake {
    public let reason: String
    private var assertion: IOPMAssertionID?

    public init(reason: String = "Hoply Away mode") {
        self.reason = reason
    }

    deinit {
        if let assertion { IOPMAssertionRelease(assertion) }
    }

    public var isActive: Bool { assertion != nil }

    @discardableResult
    public func begin() -> Bool {
        guard assertion == nil else { return true }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        guard result == kIOReturnSuccess else { return false }
        assertion = id
        return true
    }

    public func end() {
        guard let assertion else { return }
        IOPMAssertionRelease(assertion)
        self.assertion = nil
    }
}
