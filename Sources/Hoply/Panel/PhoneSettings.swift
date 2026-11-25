import AgentKit
import SwiftUI

struct PhoneSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.edition) private var edition
    @Environment(\.clock) private var clock

    static let appStoreURL = URL(string: "https://apps.apple.com/app/id6835517348")!

    private var appStoreLine: AttributedString {
        var name = AttributedString("Hoply for iPhone")
        name.link = Self.appStoreURL
        return name + AttributedString(" on the App Store: approve and reply from your phone.")
    }

    var body: some View {
        let link = model.iCloudLink
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("iPhone")
                Text(appStoreLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SwitchRow("Reach Hoply from your iPhone through iCloud", isOn: Binding(
                    get: { link.isAvailable && model.settings.iCloudLink },
                    set: { on in model.update { $0.iCloudLink = on } }
                ))
                .disabled(!link.isAvailable)
                Hint("Writes session titles, projects, costs, waiting requests and each agent's last message to your own private iCloud, encrypted, for Hoply on an iPhone with the same Apple ID. Nothing goes to any other server.")
                if let line = Self.status(link, now: clock.now) {
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
                SwitchRow("Show conversations on iPhone", isOn: Binding(
                    get: { link.isAvailable && model.settings.iCloudLink && model.settings.iPhoneConversations },
                    set: { on in model.update { $0.iPhoneConversations = on } }
                ))
                .disabled(!link.isAvailable || !model.settings.iCloudLink)
                Hint("Only for a session you open on the iPhone: its prompts, replies and one line per tool call go to your iCloud, encrypted, never tool output or file contents. Turning this off removes them from iCloud.")
                if edition.offersPhoneLaunch {
                    Divider()
                    SwitchRow("Let iPhone start sessions", isOn: Binding(
                        get: { link.isAvailable && model.settings.iCloudLink && model.settings.iPhoneLaunch },
                        set: { on in model.update { $0.iPhoneLaunch = on } }
                    ))
                    .disabled(!link.isAvailable || !model.settings.iCloudLink)
                    Hint("New and continued sessions open in Terminal on this Mac, only in projects Hoply already knows, and still ask for approvals.")
                }
                Divider()
                SwitchRow("Share history with your other Macs", isOn: Binding(
                    get: { link.isAvailable && model.settings.iCloudLink && model.settings.iCloudHistory },
                    set: { on in model.update { $0.iCloudHistory = on } }
                ))
                .disabled(!link.isAvailable || !model.settings.iCloudLink)
                Hint("Each day's sessions, project names and tokens go to your own iCloud, encrypted, for your other Macs with Hoply. Never paths or prompts. Turning this off removes them from iCloud.")
                if link.isAvailable, model.settings.sharesHistory, let failure = link.historyFailure {
                    HistoryFailureRow(failure: failure)
                }
            }
        }
    }

    static func status(_ link: ICloudLink, now: Date) -> (text: String, color: Color)? {
        guard link.isAvailable else { return ("This build of Hoply can't use iCloud", .secondary) }
        switch link.status {
        case .off:
            return nil
        case .unavailable:
            return ("This build of Hoply can't use iCloud", .secondary)
        case .connecting:
            return ("Connecting to iCloud…", .secondary)
        case .running:
            return (link.lastSync.map { "On · last synced \(Format.clock($0, now: now))" } ?? "On", .green)
        case .noAccount:
            return ("Sign in to iCloud in System Settings", .orange)
        case .restricted:
            return ("iCloud is restricted on this Mac", .orange)
        case .storageFull(let retryAt):
            return ("iCloud storage is full\(retrying(retryAt, now: now))", .orange)
        case .limited(let retryAt):
            return ("iCloud asked Hoply to slow down\(retrying(retryAt, now: now))", .orange)
        case .offline(let retryAt):
            return ("Can't reach iCloud\(retrying(retryAt, now: now))", .orange)
        case .failed(let message, let retryAt):
            return ("iCloud error: \(message)\(retrying(retryAt, now: now))", .red)
        case .removing:
            return ("Removing Hoply's records from iCloud…", .secondary)
        case .removeFailed(let retryAt):
            return ("Couldn't remove Hoply's records from iCloud yet\(retrying(retryAt, now: now))", .orange)
        }
    }

    private static func retrying(_ date: Date, now: Date) -> String {
        date.timeIntervalSince(now) < 60 ? " · retrying" : " · retrying at \(Format.clock(date, now: now))"
    }
}

private struct HistoryFailureRow: View {
    let failure: HistorySyncFailure
    @Environment(\.clock) private var clock

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(.orange)
                .frame(width: 7, height: 7)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: String {
        let since = Format.shortWhen(failure.since, now: clock.now)
        switch (failure.operation, failure.problem) {
        case (.publish, .rejected): return "Can't send history to your other Macs since \(since). iCloud refused the records."
        case (.publish, .other): return "Can't send history to your other Macs since \(since)."
        case (.fetch, .rejected): return "Can't receive history from your other Macs since \(since). iCloud refused the request."
        case (.fetch, .other): return "Can't receive history from your other Macs since \(since)."
        }
    }
}
