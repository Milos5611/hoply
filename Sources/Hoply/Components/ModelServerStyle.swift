import AgentKit
import SwiftUI

extension ModelServerHealth {
    var label: String {
        switch self {
        case .paused: return "Off"
        case .invalid: return "Check URL"
        case .connecting: return "Connecting…"
        case .live: return "Live"
        case .offline: return "Offline"
        case .signIn: return "Sign-in"
        case .setup: return "Setup"
        }
    }

    var detail: String {
        switch self {
        case .signIn: return "Sign-in needed"
        case .setup: return "Needs setup"
        default: return label
        }
    }

    var color: Color {
        switch self {
        case .paused, .connecting: return .secondary
        case .live: return .green
        case .offline: return .red
        case .invalid, .signIn, .setup: return .orange
        }
    }

    var symbol: String {
        switch self {
        case .paused: return "pause.circle"
        case .invalid, .setup: return "exclamationmark.triangle.fill"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .live: return "checkmark.circle.fill"
        case .offline: return "wifi.slash"
        case .signIn: return "lock.fill"
        }
    }
}

enum ModelServerText {
    struct Figure: Equatable {
        var value: String
        var unit: String
    }

    static func engine(_ server: ModelServer, _ state: ModelServers.State?) -> String {
        if let detected = state?.status?.engine { return detected.displayName }
        return server.engine?.displayName ?? "Auto-detect"
    }

    static func figure(_ status: ModelServerStatus) -> Figure? {
        let capabilities = status.capabilities
        if capabilities.contains(.generationRate) {
            return Figure(value: status.generationTokensPerSecond.map { "\(Format.whole($0))" } ?? "–", unit: "tok/s")
        }
        if capabilities.contains(.loadedModels) {
            return Figure(value: "\(status.snapshot.loadedModels.count)", unit: "loaded")
        }
        if capabilities.contains(.models) {
            return Figure(value: "\(status.models.count)", unit: status.models.count == 1 ? "model" : "models")
        }
        return nil
    }

    static func memory(_ bytes: Double) -> String {
        Format.bytes(Int64(Format.whole(bytes)))
    }

    static func summary(_ server: ModelServer, _ state: ModelServers.State?, health: ModelServerHealth) -> String {
        var parts = [server.displayName, engine(server, state), health.detail]
        if let figure = state?.online.flatMap(figure) { parts.append("\(figure.value) \(figure.unit)") }
        return parts.joined(separator: " · ")
    }
}

struct ModelServerDot: View {
    let health: ModelServerHealth
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(health.color.opacity(health == .paused ? 0.5 : 1))
            .frame(width: size, height: size)
            .accessibilityLabel(health.detail)
    }
}
