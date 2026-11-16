import AgentKit
import SwiftUI

struct ReplyStrip: View {
    @Environment(AppModel.self) private var model
    let reply: TurnReplyRequest

    @State private var text = ""
    @State private var expanded = false

    var body: some View {
        let tail = reply.message.map { Format.tail($0, characters: 240, lines: 4) }
        let truncated = tail?.hasPrefix(Format.tailMark) ?? false
        VStack(alignment: .leading, spacing: 6) {
            if let message = reply.message, let tail {
                Text(expanded || !truncated ? message : tail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            TextField(AwayText.placeholder(reply.key.source), text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit(send)
            HStack(spacing: 6) {
                Text("Waits until \(Format.clock(reply.received.addingTimeInterval(TurnReply.holdLimit)))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("\(reply.key.source.displayName) waits for your answer until then; after that the turn ends as usual")
                if truncated {
                    Button(expanded ? "Show less" : "Show all") { expanded.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                }
                Spacer(minLength: 6)
                Button("Done") { model.finishReply(reply.id) }
                    .buttonStyle(.bordered)
                    .help("End the turn here, as it would without Hoply")
                Button("Send") { send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
                    .help("\(AwayText.agentName(reply.key.source)) continues with your message")
            }
            .controlSize(.small)
        }
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        model.reply(reply.id, text: trimmed)
    }
}
