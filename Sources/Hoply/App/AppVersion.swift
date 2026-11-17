import Foundation

enum AppVersion {
    static var short: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static var full: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short ?? "?") (\(build))"
    }
}
