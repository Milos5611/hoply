import AgentKit
import Foundation
import os

public enum Log {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.coolcraftcoders.hoply"

    public static let icloud = Logger(subsystem: subsystem, category: "icloud")
    public static let history = Logger(subsystem: subsystem, category: "history")
    public static let ingest = Logger(subsystem: subsystem, category: "ingest")
    public static let store = Logger(subsystem: subsystem, category: "store")

    public static func code(of error: any Error) -> String {
        if let error = error as? SQLiteError { return "SQLite \(error.code)" }
        if let failure = error as? CloudLinkFailure { return code(of: failure.cause) }
        if let error = error as? CloudLinkError { return "CloudLinkError.\(error.name)" }
        let error = error as NSError
        var text = "\(error.domain) \(error.code)"
        let causes = HistorySyncHealth.causes(of: error)
        if !causes.isEmpty { text += " [" + causes.map { "\($0.domain) \($0.code)" }.joined(separator: ", ") + "]" }
        return text
    }
}
