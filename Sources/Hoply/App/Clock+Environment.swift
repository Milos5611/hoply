import SwiftUI

struct HoplyClock: Sendable {
    var fixed: Date?

    static let live = HoplyClock(fixed: nil)

    var now: Date { fixed ?? Date() }
}

extension EnvironmentValues {
    @Entry var clock: HoplyClock = .live
}
