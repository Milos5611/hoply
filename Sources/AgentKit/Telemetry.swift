import Foundation

/// An OpenTelemetry attribute value.
public enum AttributeValue: Equatable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case array([AttributeValue])
    case map([String: AttributeValue])
    case bytes(Data)

    public var string: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return String(value)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .string(let value): return Double(value)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    public var int: Int? {
        switch self {
        case .int(let value): return Int(value)
        case .double(let value): return Self.safeInt(value)
        case .string(let value): return Int(value) ?? Double(value).flatMap(Self.safeInt)
        default: return nil
        }
    }

    private static func safeInt(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) < 9.0e18 else { return nil }
        return Int(value)
    }
}

/// One log record or span, flattened from an OTLP export request.
public struct TelemetryRecord: Equatable, Sendable {
    public enum Signal: String, Sendable {
        case log
        case span
    }

    public var signal: Signal
    public var name: String
    public var attributes: [String: AttributeValue]
    public var resource: [String: AttributeValue]
    public var time: Date?
    /// Lowercase hex, whichever encoding the exporter used; nil when absent or all zeros.
    public var traceID: String?
    public var spanID: String?
    /// The exact OTLP timestamp behind `time` (log time, else observed time; span end, else start).
    public var timeUnixNano: UInt64?

    public init(signal: Signal, name: String, attributes: [String: AttributeValue],
                resource: [String: AttributeValue], time: Date?, traceID: String? = nil, spanID: String? = nil,
                timeUnixNano: UInt64? = nil) {
        self.signal = signal
        self.name = name
        self.attributes = attributes
        self.resource = resource
        self.time = time
        self.traceID = traceID
        self.spanID = spanID
        self.timeUnixNano = timeUnixNano
    }

    public subscript(_ key: String) -> AttributeValue? { attributes[key] }

    /// First attribute among `keys` that is present, looking at record attributes then resource.
    public func first(_ keys: [String]) -> AttributeValue? {
        for key in keys {
            if let value = attributes[key] { return value }
        }
        for key in keys {
            if let value = resource[key] { return value }
        }
        return nil
    }
}
