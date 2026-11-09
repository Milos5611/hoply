import AgentKit
import Foundation

extension AppSettings {
    private static let defaultsKey = "HoplySettings"

    static func load() -> AppSettings {
        decode(UserDefaults.standard.data(forKey: defaultsKey))
    }

    func save() {
        if let data = encoded() {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
