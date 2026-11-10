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

extension AppSettings {
    /// `self` with every field that `edited` changed from `base`, so saving a draft loaded from `base` keeps
    /// what changed elsewhere since. Fields are found through the JSON encoding: a new Codable setting is
    /// covered without a change here.
    func applying(_ edited: AppSettings, since base: AppSettings) -> AppSettings {
        guard let current = jsonObject, let changed = edited.jsonObject, let origin = base.jsonObject else {
            return edited
        }
        var merged = current
        for (key, value) in changed where !Self.same(value, origin[key]) {
            merged[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged) else { return edited }
        var result = AppSettings.decode(data)
        // A list both sides can edit: the draft's removals and additions are applied to the current list.
        let removed = Set(base.mutedProjectRoots).subtracting(edited.mutedProjectRoots)
        let added = edited.mutedProjectRoots.filter { !base.mutedProjectRoots.contains($0) }
        result.mutedProjectRoots = mutedProjectRoots.filter { !removed.contains($0) }
            + added.filter { !mutedProjectRoots.contains($0) }
        return result
    }

    private var jsonObject: [String: Any]? {
        encoded().flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }

    private static func same(_ value: Any, _ other: Any?) -> Bool {
        guard let other else { return false }
        return (value as? NSObject)?.isEqual(other) ?? false
    }
}
