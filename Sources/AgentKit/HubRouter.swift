import Foundation

public struct HubRouter: Sendable {
    public struct Outcome: Sendable {
        public var response: HTTPResponse
        public var events: [AgentEvent]
        public var usage: [UsageRecord]
        public var prompts: [PromptRecord]
        public var note: String?

        public init(response: HTTPResponse, events: [AgentEvent], usage: [UsageRecord] = [],
                    prompts: [PromptRecord] = [], note: String?) {
            self.response = response
            self.events = events
            self.usage = usage
            self.prompts = prompts
            self.note = note
        }
    }

    public init() {}

    public func handle(_ request: HTTPRequest, now: Date = Date()) -> Outcome {
        let path = request.path
        if request.method == "GET" && (path == "/health" || path == "/") {
            return Outcome(response: .text("Hoply is listening\n"), events: [], note: nil)
        }
        guard request.method == "POST" else {
            return Outcome(response: .notFound, events: [], note: nil)
        }
        if path.hasPrefix("/v1/") {
            return handleOTLP(request, now: now)
        }
        if path.hasPrefix("/hooks/") {
            return handleHook(request, now: now)
        }
        return Outcome(response: .notFound, events: [], note: "Unknown path \(path)")
    }

    func handleOTLP(_ request: HTTPRequest, now: Date) -> Outcome {
        let contentType = request.headers["content-type"]?.lowercased() ?? ""
        let isJSON: Bool
        if contentType.contains("json") {
            isJSON = true
        } else if contentType.contains("protobuf") || contentType.contains("proto") {
            isJSON = false
        } else {
            isJSON = request.body.first == UInt8(ascii: "{")
        }
        let ok: HTTPResponse = isJSON ? .json() : .protobufOK

        if let encoding = request.headers["content-encoding"]?.lowercased(), encoding != "identity", !encoding.isEmpty {
            let message = "Compressed OTLP (\(encoding)) is not supported; set OTEL_EXPORTER_OTLP_COMPRESSION=none"
            return Outcome(response: .text(message, status: 415, reason: "Unsupported Media Type"),
                           events: [], note: message)
        }
        if request.path.hasSuffix("/v1/metrics") {
            return Outcome(response: ok, events: [], note: nil)
        }
        do {
            let records = try OTLPDecoder.decode(path: request.path, body: request.body,
                                                 encoding: isJSON ? .json : .protobuf)
            return Outcome(response: ok, events: TelemetryMapper.events(from: records, now: now),
                           usage: TelemetryUsage.records(from: records),
                           prompts: TelemetryUsage.prompts(from: records), note: nil)
        } catch OTLPError.unknownSignal {
            return Outcome(response: .notFound, events: [], note: "Unknown OTLP path \(request.path)")
        } catch {
            return Outcome(response: .badRequest("Could not decode OTLP payload"), events: [],
                           note: "Undecodable OTLP payload on \(request.path)")
        }
    }

    func handleHook(_ request: HTTPRequest, now: Date) -> Outcome {
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, let source = AgentSource(rawValue: parts[1]) else {
            return Outcome(response: .notFound, events: [], note: "Unknown hook source in \(request.path)")
        }
        let eventName = parts.count >= 3 ? parts[2] : nil
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return Outcome(response: .badRequest("Expected a JSON object"), events: [],
                           note: "Hook \(source.rawValue) sent a non-JSON body")
        }
        let events = HookMapper.events(source: source, eventName: eventName, json: json,
                                       agentPID: Self.agentPID(request), now: now)
        return Outcome(response: .json(), events: events, note: nil)
    }

    public static let agentPIDHeader = "x-hoply-pid"

    static func agentPID(_ request: HTTPRequest) -> Int32? {
        guard let text = request.headers[agentPIDHeader], let pid = Int32(text), pid > 1 else { return nil }
        return pid
    }
}
