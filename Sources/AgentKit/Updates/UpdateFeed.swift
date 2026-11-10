import Foundation

public struct UpdateFeed: Equatable, Sendable {
    public let url: URL
    public let publicKey: String

    public init?(info: [String: Any]) {
        guard let address = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespaces),
              let url = URL(string: address), url.scheme?.lowercased() == "https", !(url.host ?? "").isEmpty,
              let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces),
              Data(base64Encoded: key)?.count == 32
        else { return nil }
        self.url = url
        publicKey = key
    }
}
