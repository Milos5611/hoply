import Foundation

public enum OTLPError: Error, Equatable {
    case malformed
    case unknownSignal
}

/// Decodes OTLP/HTTP export requests (logs and traces) in both JSON and protobuf encodings
/// into flat `TelemetryRecord`s. Metrics are accepted by the server but not decoded: they are
/// periodic aggregates and say nothing about what an agent is doing right now.
public enum OTLPDecoder {
    public enum Encoding: Sendable {
        case json
        case protobuf
    }

    public static func decode(path: String, body: Data, encoding: Encoding) throws -> [TelemetryRecord] {
        let signal: TelemetryRecord.Signal
        if path.hasSuffix("/v1/logs") {
            signal = .log
        } else if path.hasSuffix("/v1/traces") {
            signal = .span
        } else {
            throw OTLPError.unknownSignal
        }
        if body.isEmpty { return [] }
        switch encoding {
        case .json: return try decodeJSON(signal: signal, body: body)
        case .protobuf: return try decodeProtobuf(signal: signal, body: body)
        }
    }

    // MARK: - JSON

    static func decodeJSON(signal: TelemetryRecord.Signal, body: Data) throws -> [TelemetryRecord] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw OTLPError.malformed
        }
        var records: [TelemetryRecord] = []
        switch signal {
        case .log:
            for resourceLogs in objects(root, ["resourceLogs", "resource_logs"]) {
                let resource = jsonResource(resourceLogs)
                for scopeLogs in objects(resourceLogs, ["scopeLogs", "scope_logs"]) {
                    for record in objects(scopeLogs, ["logRecords", "log_records"]) {
                        let attributes = jsonAttributes(objects(record, ["attributes"]))
                        let bodyValue = object(record, ["body"]).map(jsonAnyValue)
                        let eventName = string(record, ["eventName", "event_name"])
                        let name = nonEmpty(eventName) ?? nonEmpty(attributes["event.name"]?.string) ?? bodyValue?.string ?? ""
                        let time = nanosToDate(record["timeUnixNano"] ?? record["time_unix_nano"])
                            ?? nanosToDate(record["observedTimeUnixNano"] ?? record["observed_time_unix_nano"])
                        records.append(TelemetryRecord(signal: .log, name: name, attributes: attributes,
                                                       resource: resource, time: time))
                    }
                }
            }
        case .span:
            for resourceSpans in objects(root, ["resourceSpans", "resource_spans"]) {
                let resource = jsonResource(resourceSpans)
                for scopeSpans in objects(resourceSpans, ["scopeSpans", "scope_spans"]) {
                    for span in objects(scopeSpans, ["spans"]) {
                        let attributes = jsonAttributes(objects(span, ["attributes"]))
                        let name = string(span, ["name"]) ?? ""
                        let time = nanosToDate(span["endTimeUnixNano"] ?? span["end_time_unix_nano"])
                            ?? nanosToDate(span["startTimeUnixNano"] ?? span["start_time_unix_nano"])
                        records.append(TelemetryRecord(signal: .span, name: name, attributes: attributes,
                                                       resource: resource, time: time))
                    }
                }
            }
        }
        return records
    }

    private static func jsonResource(_ container: [String: Any]) -> [String: AttributeValue] {
        guard let resource = object(container, ["resource"]) else { return [:] }
        return jsonAttributes(objects(resource, ["attributes"]))
    }

    private static func jsonAttributes(_ list: [[String: Any]]) -> [String: AttributeValue] {
        var result: [String: AttributeValue] = [:]
        for pair in list {
            guard let key = pair["key"] as? String else { continue }
            if let value = pair["value"] as? [String: Any] {
                result[key] = jsonAnyValue(value)
            }
        }
        return result
    }

    private static func jsonAnyValue(_ value: [String: Any]) -> AttributeValue {
        if let text = (value["stringValue"] ?? value["string_value"]) as? String {
            return .string(text)
        }
        if let flag = value["boolValue"] ?? value["bool_value"] {
            if let bool = flag as? Bool { return .bool(bool) }
            if let text = flag as? String { return .bool(text == "true") }
        }
        if let raw = value["intValue"] ?? value["int_value"] {
            if let text = raw as? String, let number = Int64(text) { return .int(number) }
            if let number = raw as? NSNumber { return .int(number.int64Value) }
        }
        if let raw = value["doubleValue"] ?? value["double_value"] {
            if let number = raw as? NSNumber { return .double(number.doubleValue) }
            if let text = raw as? String, let number = Double(text) { return .double(number) }
        }
        if let array = object(value, ["arrayValue", "array_value"]) {
            return .array(objects(array, ["values"]).map(jsonAnyValue))
        }
        if let list = object(value, ["kvlistValue", "kvlist_value"]) {
            return .map(jsonAttributes(objects(list, ["values"])))
        }
        if let text = (value["bytesValue"] ?? value["bytes_value"]) as? String {
            return .bytes(Data(base64Encoded: text) ?? Data())
        }
        return .string("")
    }

    private static func objects(_ dict: [String: Any], _ keys: [String]) -> [[String: Any]] {
        for key in keys {
            if let list = dict[key] as? [[String: Any]] { return list }
        }
        return []
    }

    private static func object(_ dict: [String: Any], _ keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dict[key] as? [String: Any] { return value }
        }
        return nil
    }

    private static func string(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String { return value }
        }
        return nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func nanosToDate(_ raw: Any?) -> Date? {
        var nanos: UInt64 = 0
        if let text = raw as? String, let value = UInt64(text) {
            nanos = value
        } else if let number = raw as? NSNumber {
            nanos = number.uint64Value
        }
        return nanos == 0 ? nil : Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
    }

    // MARK: - Protobuf

    static func decodeProtobuf(signal: TelemetryRecord.Signal, body: Data) throws -> [TelemetryRecord] {
        var records: [TelemetryRecord] = []
        var root = ProtoReader(body)
        // ExportLogsServiceRequest / ExportTraceServiceRequest: field 1 = Resource{Logs,Spans}
        while let tag = try root.readTag() {
            guard tag.field == 1, tag.wireType == 2 else {
                try root.skip(wireType: tag.wireType)
                continue
            }
            let resourceBlock = try root.readLengthDelimited()
            var reader = ProtoReader(resourceBlock)
            var resource: [String: AttributeValue] = [:]
            var scopeBlocks: [[UInt8]] = []
            while let inner = try reader.readTag() {
                if inner.field == 1, inner.wireType == 2 {
                    resource = try pbResource(reader.readLengthDelimited())
                } else if inner.field == 2, inner.wireType == 2 {
                    scopeBlocks.append(try reader.readLengthDelimited())
                } else {
                    try reader.skip(wireType: inner.wireType)
                }
            }
            for scopeBlock in scopeBlocks {
                var scope = ProtoReader(scopeBlock)
                // Scope{Logs,Spans}: field 2 = LogRecord / Span
                while let item = try scope.readTag() {
                    guard item.field == 2, item.wireType == 2 else {
                        try scope.skip(wireType: item.wireType)
                        continue
                    }
                    let bytes = try scope.readLengthDelimited()
                    switch signal {
                    case .log: records.append(try pbLogRecord(bytes, resource: resource))
                    case .span: records.append(try pbSpan(bytes, resource: resource))
                    }
                }
            }
        }
        return records
    }

    private static func pbLogRecord(_ bytes: [UInt8], resource: [String: AttributeValue]) throws -> TelemetryRecord {
        var reader = ProtoReader(bytes)
        var time: UInt64 = 0
        var observed: UInt64 = 0
        var body: AttributeValue?
        var attributes: [String: AttributeValue] = [:]
        var eventName = ""
        while let tag = try reader.readTag() {
            switch (tag.field, tag.wireType) {
            case (1, 1): time = try reader.readFixed64()
            case (11, 1): observed = try reader.readFixed64()
            case (5, 2): body = try pbAnyValue(reader.readLengthDelimited())
            case (6, 2):
                let pair = try pbKeyValue(reader.readLengthDelimited())
                if let pair { attributes[pair.key] = pair.value }
            case (12, 2): eventName = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            default: try reader.skip(wireType: tag.wireType)
            }
        }
        let name = !eventName.isEmpty ? eventName : (attributes["event.name"]?.string ?? body?.string ?? "")
        let nanos = time != 0 ? time : observed
        let date = nanos == 0 ? nil : Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
        return TelemetryRecord(signal: .log, name: name, attributes: attributes, resource: resource, time: date)
    }

    private static func pbSpan(_ bytes: [UInt8], resource: [String: AttributeValue]) throws -> TelemetryRecord {
        var reader = ProtoReader(bytes)
        var name = ""
        var start: UInt64 = 0
        var end: UInt64 = 0
        var attributes: [String: AttributeValue] = [:]
        while let tag = try reader.readTag() {
            switch (tag.field, tag.wireType) {
            case (5, 2): name = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (7, 1): start = try reader.readFixed64()
            case (8, 1): end = try reader.readFixed64()
            case (9, 2):
                let pair = try pbKeyValue(reader.readLengthDelimited())
                if let pair { attributes[pair.key] = pair.value }
            default: try reader.skip(wireType: tag.wireType)
            }
        }
        let nanos = end != 0 ? end : start
        let date = nanos == 0 ? nil : Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
        return TelemetryRecord(signal: .span, name: name, attributes: attributes, resource: resource, time: date)
    }

    private static func pbResource(_ bytes: [UInt8]) throws -> [String: AttributeValue] {
        var reader = ProtoReader(bytes)
        var attributes: [String: AttributeValue] = [:]
        while let tag = try reader.readTag() {
            if tag.field == 1, tag.wireType == 2 {
                let pair = try pbKeyValue(reader.readLengthDelimited())
                if let pair { attributes[pair.key] = pair.value }
            } else {
                try reader.skip(wireType: tag.wireType)
            }
        }
        return attributes
    }

    private static func pbKeyValue(_ bytes: [UInt8]) throws -> (key: String, value: AttributeValue)? {
        var reader = ProtoReader(bytes)
        var key: String?
        var value: AttributeValue = .string("")
        while let tag = try reader.readTag() {
            switch (tag.field, tag.wireType) {
            case (1, 2): key = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (2, 2): value = try pbAnyValue(reader.readLengthDelimited())
            default: try reader.skip(wireType: tag.wireType)
            }
        }
        guard let key else { return nil }
        return (key, value)
    }

    private static func pbAnyValue(_ bytes: [UInt8]) throws -> AttributeValue {
        var reader = ProtoReader(bytes)
        var value: AttributeValue = .string("")
        while let tag = try reader.readTag() {
            switch (tag.field, tag.wireType) {
            case (1, 2):
                let raw = try reader.readLengthDelimited()
                value = .string(String(decoding: raw, as: UTF8.self))
            case (2, 0):
                let raw = try reader.readVarint()
                value = .bool(raw != 0)
            case (3, 0):
                let raw = try reader.readVarint()
                value = .int(Int64(bitPattern: raw))
            case (4, 1):
                let raw = try reader.readFixed64()
                value = .double(Double(bitPattern: raw))
            case (5, 2):
                let raw = try reader.readLengthDelimited()
                value = .array(try pbRepeatedAnyValue(raw))
            case (6, 2):
                let raw = try reader.readLengthDelimited()
                value = .map(try pbKeyValueList(raw))
            case (7, 2):
                let raw = try reader.readLengthDelimited()
                value = .bytes(Data(raw))
            default:
                try reader.skip(wireType: tag.wireType)
            }
        }
        return value
    }

    /// ArrayValue: field 1 = repeated AnyValue.
    private static func pbRepeatedAnyValue(_ bytes: [UInt8]) throws -> [AttributeValue] {
        var reader = ProtoReader(bytes)
        var values: [AttributeValue] = []
        while let tag = try reader.readTag() {
            if tag.field == 1, tag.wireType == 2 {
                values.append(try pbAnyValue(reader.readLengthDelimited()))
            } else {
                try reader.skip(wireType: tag.wireType)
            }
        }
        return values
    }

    /// KeyValueList: field 1 = repeated KeyValue.
    private static func pbKeyValueList(_ bytes: [UInt8]) throws -> [String: AttributeValue] {
        var reader = ProtoReader(bytes)
        var result: [String: AttributeValue] = [:]
        while let tag = try reader.readTag() {
            if tag.field == 1, tag.wireType == 2 {
                if let pair = try pbKeyValue(reader.readLengthDelimited()) { result[pair.key] = pair.value }
            } else {
                try reader.skip(wireType: tag.wireType)
            }
        }
        return result
    }
}

/// Minimal protobuf wire-format reader: enough to walk OTLP messages without generated code.
struct ProtoReader {
    struct Tag {
        let field: Int
        let wireType: Int
    }

    private let bytes: [UInt8]
    private(set) var index = 0

    init(_ data: Data) { self.bytes = [UInt8](data) }
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func readTag() throws -> Tag? {
        if isAtEnd { return nil }
        let key = try readVarint()
        let field = Int(truncatingIfNeeded: key >> 3)
        let wireType = Int(key & 0x7)
        guard field > 0 else { throw OTLPError.malformed }
        return Tag(field: field, wireType: wireType)
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count, shift < 64 else { throw OTLPError.malformed }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func readFixed64() throws -> UInt64 {
        guard index + 8 <= bytes.count else { throw OTLPError.malformed }
        var value: UInt64 = 0
        for offset in 0..<8 {
            value |= UInt64(bytes[index + offset]) << UInt64(8 * offset)
        }
        index += 8
        return value
    }

    mutating func readLengthDelimited() throws -> [UInt8] {
        let length = try readVarint()
        guard length <= UInt64(bytes.count - index) else { throw OTLPError.malformed }
        let end = index + Int(length)
        let slice = Array(bytes[index..<end])
        index = end
        return slice
    }

    mutating func skip(wireType: Int) throws {
        switch wireType {
        case 0:
            _ = try readVarint()
        case 1:
            guard index + 8 <= bytes.count else { throw OTLPError.malformed }
            index += 8
        case 2:
            _ = try readLengthDelimited()
        case 5:
            guard index + 4 <= bytes.count else { throw OTLPError.malformed }
            index += 4
        default:
            throw OTLPError.malformed
        }
    }
}
