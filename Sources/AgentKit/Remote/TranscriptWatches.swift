import Foundation

public struct TranscriptSignal: Sendable, Equatable {
    public var path: String
    public var size: Int64
    public var modified: Date

    public init(path: String, size: Int64, modified: Date) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}

public struct TranscriptWatches: Sendable, Equatable {
    public struct Watch: Sendable, Equatable {
        public var session: String
        public var answerID: String
        public var requestedAt: Date
        public var until: Date
        public var builtAt: Date?
        public var signal: TranscriptSignal?
        public var published: RemoteTranscript?
        var builtSignal: TranscriptSignal?

        var isServed: Bool { published?.answerID == answerID }
    }

    public private(set) var watches: [String: Watch] = [:]

    public init() {}

    public var isEmpty: Bool { watches.isEmpty }
    public var sessions: [String] { watches.keys.sorted() }

    public func watch(_ session: String) -> Watch? { watches[session] }

    public mutating func add(_ orders: [RemoteTranscriptOrder], now: Date) {
        let ordered = orders.enumerated()
            .sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }
            .map(\.element)
        for order in ordered {
            // A phone clock running ahead must not stretch the watch past `watchFor` from now.
            let requested = min(order.createdAt, now)
            let until = requested.addingTimeInterval(RemoteTranscriptPolicy.watchFor)
            guard var watch = watches[order.session] else {
                watches[order.session] = Watch(session: order.session, answerID: order.answerID,
                                               requestedAt: requested, until: until)
                continue
            }
            if requested >= watch.requestedAt {
                watch.answerID = order.answerID
                watch.requestedAt = requested
            }
            watch.until = max(watch.until, until)
            watches[order.session] = watch
        }
    }

    public func due(_ signals: [String: TranscriptSignal], now: Date) -> [Watch] {
        watches.values.filter { watch in
            guard now < watch.until || !watch.isServed else { return false }
            guard let builtAt = watch.builtAt, watch.isServed else { return true }
            return signals[watch.session] != watch.signal
                && now.timeIntervalSince(builtAt) >= RemoteTranscriptPolicy.refreshEvery
        }
        .sorted { $0.session < $1.session }
    }

    public mutating func built(_ transcript: RemoteTranscript, signal: TranscriptSignal?, at time: Date) -> Bool {
        guard var watch = watches[transcript.session] else { return false }
        watch.builtAt = time
        let publish = !(watch.published?.sameContent(as: transcript) ?? false)
        // The file state counts as seen only once the phone can see it too, so a failed save is rebuilt.
        if publish { watch.builtSignal = signal } else { watch.signal = signal }
        watches[transcript.session] = watch
        return publish
    }

    public mutating func published(_ transcript: RemoteTranscript) {
        guard var watch = watches[transcript.session] else { return }
        watch.published = transcript
        watch.signal = watch.builtSignal
        watches[transcript.session] = watch
    }

    @discardableResult
    public mutating func expire(now: Date) -> [String] {
        let gone = watches.values.filter { watch in
            let abandoned = now >= watch.until.addingTimeInterval(RemoteTranscriptPolicy.watchFor)
            return now >= watch.until && (watch.isServed || abandoned)
        }
        .map(\.session).sorted()
        for session in gone { watches[session] = nil }
        return gone
    }

    public func stale(_ records: [String: Date], device: String, enabled: Bool = true, now: Date) -> [String] {
        guard enabled else { return records.keys.sorted() }
        let watched = Set(watches.keys.map { RemoteSchema.transcriptRecordName(device: device, session: $0) })
        var gone: [String] = []
        var kept: [(name: String, at: Date)] = []
        for (name, at) in records where !watched.contains(name) {
            if now.timeIntervalSince(at) > RemoteTranscriptPolicy.recordLifetime {
                gone.append(name)
            } else {
                kept.append((name, at))
            }
        }
        let room = max(RemoteTranscriptPolicy.maxRecords - records.keys.filter(watched.contains).count, 0)
        kept.sort { ($0.at, $0.name) > ($1.at, $1.name) }
        gone += kept.dropFirst(room).map(\.name)
        return gone.sorted()
    }
}

extension RemoteTranscript {
    public static func build(device: String, session: String, agent: String, answerID: String?,
                             messages: [Message], earlierOmitted: Bool = false, now: Date) -> RemoteTranscript {
        let policy = RemoteTranscriptPolicy.self
        let recent = messages.suffix(policy.maxMessages).map(clipped)
        var transcript = RemoteTranscript(device: device, session: session, agent: agent, answerID: answerID,
                                          updatedAt: now, messages: Array(recent),
                                          truncated: earlierOmitted || messages.count > recent.count)
        guard var size = encodedSize(transcript), size > policy.byteLimit else { return transcript }
        transcript.truncated = true
        let sizes = transcript.messages.map { encodedSize($0) ?? 0 }
        var dropped = 0
        while size > policy.byteLimit, dropped < sizes.count - 1 {
            size -= sizes[dropped] + 1
            dropped += 1
        }
        transcript.messages.removeFirst(dropped)
        while !transcript.messages.isEmpty, (encodedSize(transcript) ?? .max) > policy.byteLimit {
            transcript.messages.removeFirst()
        }
        return transcript
    }

    public static func failed(_ problem: Problem, device: String, session: String, agent: String,
                              answerID: String?, now: Date) -> RemoteTranscript {
        RemoteTranscript(device: device, session: session, agent: agent, answerID: answerID, updatedAt: now,
                         problem: problem)
    }

    static func clipped(_ message: Message) -> Message {
        let policy = RemoteTranscriptPolicy.self
        let limit = message.role == .tool ? policy.toolLimit : policy.textLimit
        var text = message.text
        if text.count > limit { text = String(text.prefix(limit)) + "…" }
        // One character can hold any number of combining marks; a single message must still fit the record.
        let budget = policy.byteLimit - 16_384
        if jsonSize(text) > budget { text = prefix(text, jsonBytes: budget - 3) + "…" }
        return Message(role: message.role, text: text, at: message.at)
    }

    private static func encodedSize<T: Encodable>(_ value: T) -> Int? {
        (try? RemoteSchema.encode(value))?.count
    }

    private static func jsonSize(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x22, 0x5C: 2
        case 0..<0x20, 0x2028, 0x2029: 6
        default: String(scalar).utf8.count
        }
    }

    private static func jsonSize(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + jsonSize($1) }
    }

    private static func prefix(_ text: String, jsonBytes budget: Int) -> String {
        var used = 0
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            used += jsonSize(scalar)
            if used > budget { break }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}

extension RemoteSchema {
    public static func sessionKey(from text: String) -> SessionKey? {
        guard let colon = text.firstIndex(of: ":"), let source = AgentSource(rawValue: String(text[..<colon]))
        else { return nil }
        let id = String(text[text.index(after: colon)...])
        return id.isEmpty ? nil : SessionKey(source: source, id: id)
    }
}
