import AgentKit
import Foundation

public enum PricingOverrides {
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Hoply/pricing.json")
    }

    public static func load(from url: URL = defaultURL) -> PricingTable.Document? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PricingTable.Document.decode(data)
    }

    public static func table(overridesURL: URL? = defaultURL, localModelPatterns: [String],
                             referenceModel: String, aliases: [String: String] = [:]) -> PricingTable {
        PricingTable.bundled(overrides: overridesURL.flatMap { load(from: $0) },
                             localModelPatterns: localModelPatterns, referenceModel: referenceModel, aliases: aliases)
    }
}
