import AgentKit
import SwiftUI

struct SessionTimelineCard: View {
    let spans: [StateSpan]

    var body: some View {
        if let first = spans.first {
            if spans.contains(where: \.isOpen) {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    card(from: first.start, now: max(context.date, first.start))
                }
            } else {
                card(from: first.start, now: spans.compactMap(\.end).max() ?? first.start)
            }
        }
    }

    private func card(from start: Date, now: Date) -> some View {
        let live = spans.contains(where: \.isOpen)
        let times = StateSpan.timeInState(spans, now: now)
        let tracked = times.values.reduce(0, +)
        return Card(prominent: true, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle("Timeline")
                    Spacer()
                    Text(live ? "\(Format.timeSpent(tracked)) · live" : Format.timeSpent(tracked))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(live ? Color.blue : Color.secondary)
                }
                VStack(spacing: 4) {
                    TimelineBar(spans: spans, start: start, end: now)
                    HStack {
                        Text(Format.when(start))
                        Spacer()
                        Text(live ? "now" : Format.when(now))
                    }
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    ForEach(Self.order.filter { (times[$0] ?? 0) > 0 }, id: \.self) { state in
                        let time = times[state] ?? 0
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(TimelineBar.color(for: state))
                                .frame(width: 8, height: 8)
                            Text(state.status.label)
                                .font(.system(size: 12))
                            Spacer(minLength: 6)
                            Text(Format.timeSpent(time))
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                            Text(time / max(tracked, 1) < 0.01 ? "<1%" : Format.percent(time / tracked))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .help("What the session was doing while Hoply watched it. Gaps are times Hoply wasn't running.")
    }

    private static let order: [SessionState] = [.working, .yourTurn, .needsPermission, .idle, .ended]
}

struct TimelineBar: View {
    let spans: [StateSpan]
    let start: Date
    let end: Date

    private static let minimumWidth: CGFloat = 1.5

    var body: some View {
        let total = max(end.timeIntervalSince(start), 1)
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Color.primary.opacity(0.07)
                ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                    let x = min(max(span.start.timeIntervalSince(start) / total, 0), 1) * width
                    let natural = span.duration(now: end) / total * width
                    // A few seconds in a six-hour session would otherwise be thinner than a pixel.
                    let shown = min(max(natural, Self.minimumWidth), max(width - x, Self.minimumWidth))
                    Rectangle()
                        .fill(Self.color(for: span.state))
                        .frame(width: shown)
                        .offset(x: min(x, width - shown))
                        .help(Self.tooltip(span, now: end))
                }
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Session timeline")
    }

    static func color(for state: SessionState) -> Color {
        StatePill.color(for: state.status).opacity(state == .idle || state == .ended ? 0.4 : 0.9)
    }

    static func tooltip(_ span: StateSpan, now: Date) -> String {
        let length = Format.timeSpent(span.duration(now: now))
        guard let end = span.end else {
            return "\(span.state.status.label) since \(Format.when(span.start)) · \(length)"
        }
        return "\(span.state.status.label) · \(Format.when(span.start)) – \(Format.when(end)) · \(length)"
    }
}

extension SessionState {
    var status: SessionStatus {
        switch self {
        case .working: return .working
        case .needsPermission: return .permission
        case .yourTurn: return .yourTurn
        case .idle: return .idle
        case .ended: return .ended
        }
    }
}
