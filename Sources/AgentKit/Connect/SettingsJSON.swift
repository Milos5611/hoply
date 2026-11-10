import Foundation

public enum SettingsJSONError: Error, Equatable, Sendable {
    case invalidJSON(String)
    case notAnObject
    case wrongShape(String)

    public var reason: String {
        switch self {
        case .invalidJSON(let detail): return detail.isEmpty ? "is not valid JSON" : "is not valid JSON (\(detail))"
        case .notAnObject: return "is not a JSON object"
        case .wrongShape(let detail): return "has an unexpected shape: \(detail)"
        }
    }
}

public enum SettingsJSON {
    public static func parse(_ data: Data) throws(SettingsJSONError) -> [String: Any] {
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return [:] }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? ""
            throw .invalidJSON(detail)
        }
        guard let object = value as? [String: Any] else { throw .notAnObject }
        return object
    }

    // Hand-written: JSONSerialization prints 0.1 as 0.10000000000000001 and {} as "{\n\n}".
    public static func encode(_ object: [String: Any]) -> Data {
        var text = ""
        write(object, indent: "", into: &text)
        text += "\n"
        return Data(text.utf8)
    }

    public static func same(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (lhs as String, rhs as String):
            return lhs == rhs
        case let (lhs as NSNumber, rhs as NSNumber):
            return isBool(lhs) == isBool(rhs) && lhs == rhs
        case let (lhs as [String: Any], rhs as [String: Any]):
            return lhs.count == rhs.count && lhs.allSatisfy { key, value in rhs[key].map { same(value, $0) } ?? false }
        case let (lhs as [Any], rhs as [Any]):
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { same($0, $1) }
        case (is NSNull, is NSNull):
            return true
        default:
            return false
        }
    }

    public static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    public static func isNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    public static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private static func write(_ value: Any, indent: String, into text: inout String) {
        let inner = indent + "  "
        switch value {
        case let string as String:
            text += quoted(string)
        case let number as NSNumber:
            text += literal(number)
        case let object as [String: Any]:
            guard !object.isEmpty else { text += "{}"; return }
            text += "{\n"
            for (index, key) in object.keys.sorted().enumerated() {
                text += inner + quoted(key) + ": "
                write(object[key] as Any, indent: inner, into: &text)
                text += index == object.count - 1 ? "\n" : ",\n"
            }
            text += indent + "}"
        case let array as [Any]:
            guard !array.isEmpty else { text += "[]"; return }
            text += "[\n"
            for (index, element) in array.enumerated() {
                text += inner
                write(element, indent: inner, into: &text)
                text += index == array.count - 1 ? "\n" : ",\n"
            }
            text += indent + "]"
        default:
            text += "null"
        }
    }

    private static func literal(_ number: NSNumber) -> String {
        if isBool(number) { return number.boolValue ? "true" : "false" }
        if number is NSDecimalNumber || !CFNumberIsFloatType(number) { return number.stringValue }
        let double = number.doubleValue
        guard double.isFinite else { return "null" }
        let text = double.description
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
