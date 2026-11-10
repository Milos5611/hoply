import AgentKit
import SwiftUI

struct ClaudeLimitsWidget: View {
    @Environment(AppModel.self) private var model

    private let claude = SourceBadge.color(for: .claudeCode)

    var body: some View {
        if !model.settings.claudeLimitsEnabled {
            WidgetTile(title: "Claude limits", symbol: "asterisk", tint: claude, footer: "Uses Claude Code's login") {
                Button("Connect") { model.enableClaudeLimits() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            Button { model.openDashboard(.limits) } label: { tile }
                .buttonStyle(.plain)
                .help(help)
        }
    }

    private var fiveHourPace: LimitPace? {
        model.claudeLimits?.fiveHour?.pace(.fiveHour, at: model.claudeLimitsFetchedAt ?? Date())
    }

    @ViewBuilder
    private var tile: some View {
        if let limits = model.claudeLimits, let fiveHour = limits.fiveHour {
            WidgetTile(title: "5-hour", symbol: "asterisk", tint: claude,
                       footer: model.claudeLimitsError ?? Format.resetTime(fiveHour.resetsAt),
                       footerColor: model.claudeLimitsError == nil ? .secondary : .red) {
                HStack(spacing: 10) {
                    RingGauge(fraction: fiveHour.utilization / 100, tint: Self.tint(fiveHour.utilization),
                              marker: fiveHourPace.map { $0.elapsedPercent / 100 }) {
                        Text(Self.percent(fiveHour.utilization))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                    .frame(width: 54, height: 54)
                    if let week = limits.sevenDay {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Week")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                            Text(Self.percent(week.utilization))
                                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        }
                    }
                }
            }
        } else {
            WidgetTile(title: "Claude limits", symbol: "asterisk", tint: claude,
                       footer: model.claudeLimitsError ?? "Loading…",
                       footerColor: model.claudeLimitsError == nil ? .secondary : .red) {
                RingGauge(fraction: 0, tint: .blue) { EmptyView() }
                    .frame(width: 54, height: 54)
            }
        }
    }

    private var help: String {
        guard let fiveHour = model.claudeLimits?.fiveHour else { return "Open Limits in the Dashboard" }
        var lines = ["5-hour window: \(Self.percent(fiveHour.utilization)) used"]
        if let pace = fiveHourPace {
            lines[0] += ", \(Self.percent(pace.elapsedPercent)) of the time gone"
            lines.append(Self.paceSentence(pace) + " The tick on the ring marks the time gone.")
        }
        lines.append("Open Limits in the Dashboard")
        return lines.joined(separator: "\n")
    }

    static func percent(_ utilization: Double) -> String {
        "\(Int(utilization.rounded()))%"
    }

    static func tint(_ utilization: Double) -> Color {
        if utilization >= 90 { return .red }
        if utilization >= 70 { return .orange }
        return .blue
    }

    static func paceSentence(_ pace: LimitPace) -> String {
        let points = Int(abs(pace.delta).rounded())
        switch pace.band {
        case .ahead: return "Ahead of an even pace by \(points) points."
        case .under: return "Under an even pace by \(points) points."
        case .onTrack: return "On an even pace."
        }
    }
}
