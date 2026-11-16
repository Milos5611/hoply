import SwiftUI

struct PhoneSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let link = model.iCloudLink
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("iPhone")
                SwitchRow("Reach Hoply from your iPhone through iCloud", isOn: Binding(
                    get: { link.isAvailable && model.settings.iCloudLink },
                    set: { on in model.update { $0.iCloudLink = on } }
                ))
                .disabled(!link.isAvailable)
                Hint("Writes session titles, projects, costs, waiting requests and each agent's last message to your own private iCloud, encrypted, for Hoply on an iPhone with the same Apple ID. Nothing goes to any other server.")
                if let line = Self.status(link) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(line.color)
                            .frame(width: 7, height: 7)
                        Text(line.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                SwitchRow("Let iPhone start sessions", isOn: Binding(
                    get: { link.isAvailable && model.settings.iCloudLink && model.settings.iPhoneLaunch },
                    set: { on in model.update { $0.iPhoneLaunch = on } }
                ))
                .disabled(!link.isAvailable || !model.settings.iCloudLink)
                Hint("New and continued sessions open in Terminal on this Mac, only in projects Hoply already knows, and still ask for approvals.")
            }
        }
    }

    static func status(_ link: ICloudLink) -> (text: String, color: Color)? {
        guard link.isAvailable else { return ("This build of Hoply can't use iCloud", .secondary) }
        switch link.status {
        case .off:
            return nil
        case .unavailable:
            return ("This build of Hoply can't use iCloud", .secondary)
        case .connecting:
            return ("Connecting to iCloud…", .secondary)
        case .running:
            return (link.lastSync.map { "On · last synced \(Format.clock($0))" } ?? "On", .green)
        case .noAccount:
            return ("Sign in to iCloud in System Settings", .orange)
        case .restricted:
            return ("iCloud is restricted on this Mac", .orange)
        case .storageFull(let retryAt):
            return ("iCloud storage is full\(retrying(retryAt))", .orange)
        case .limited(let retryAt):
            return ("iCloud asked Hoply to slow down\(retrying(retryAt))", .orange)
        case .offline(let retryAt):
            return ("Can't reach iCloud\(retrying(retryAt))", .orange)
        case .failed(let message, let retryAt):
            return ("iCloud error: \(message)\(retrying(retryAt))", .red)
        case .removing:
            return ("Removing Hoply's records from iCloud…", .secondary)
        case .removeFailed(let retryAt):
            return ("Couldn't remove Hoply's records from iCloud yet\(retrying(retryAt))", .orange)
        }
    }

    private static func retrying(_ date: Date, now: Date = Date()) -> String {
        date.timeIntervalSince(now) < 60 ? " · retrying" : " · retrying at \(Format.clock(date, now: now))"
    }
}
