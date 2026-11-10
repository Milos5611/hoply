import AgentKit
import Foundation

extension StoreReader {
    public func lastSampleEnd(_ series: [String]) throws -> Date? {
        guard !series.isEmpty else { return nil }
        let marks = Array(repeating: "?", count: series.count).joined(separator: ", ")
        let end = try db.queryOne("SELECT MAX(bucket + res) FROM samples WHERE series IN (\(marks))", series) {
            $0.optionalDouble(0)
        } ?? nil
        return end.map { Date(timeIntervalSince1970: $0) }
    }

    public func modelServerIDsWithSamples() throws -> [String] {
        let names = try db.query("SELECT DISTINCT series FROM samples WHERE series LIKE 'model.%'") { $0.text(0) }
        var ids: Set<String> = []
        for name in names {
            let parts = name.split(separator: ".")
            ids.insert(parts.count == 3 ? String(parts[1]) : ModelServer.legacyID)
        }
        return ids.sorted()
    }
}
