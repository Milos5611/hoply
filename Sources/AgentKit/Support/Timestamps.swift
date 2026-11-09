import Foundation

public enum Timestamps {
    /// Accepts epoch seconds or milliseconds (as a number) or an ISO 8601 string.
    public static func date(_ raw: Any?) -> Date? {
        if let number = raw as? NSNumber {
            let value = number.doubleValue
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
        }
        guard let text = raw as? String, !text.isEmpty else { return nil }
        return parse(text)
    }

    public static func parse(_ text: String) -> Date? {
        if let seconds = epochSeconds(text) { return Date(timeIntervalSince1970: seconds) }
        if let date = try? Date(text, strategy: fractional) { return date }
        return try? Date(text, strategy: plain)
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    /// Fast path for `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH[:]MM)`, the shape every transcript line uses.
    /// Any fraction length works, which ISO8601DateFormatter does not handle.
    static func epochSeconds(_ text: String) -> Double? {
        var bytes = Array(text.utf8)
        guard bytes.count >= 20 else { return nil }
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for index in start..<(start + length) {
                let byte = bytes[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: "t") || bytes[10] == UInt8(ascii: " "),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second <= 60 else { return nil }

        var index = 19
        var fraction = 0.0
        if bytes[index] == UInt8(ascii: ".") {
            index += 1
            var scale = 0.1
            let start = index
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
            guard index > start else { return nil }
        }
        guard index < bytes.count else { return nil }
        var offset = 0
        switch bytes[index] {
        case UInt8(ascii: "Z"), UInt8(ascii: "z"):
            guard index + 1 == bytes.count else { return nil }
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            let sign = bytes[index] == UInt8(ascii: "+") ? 1 : -1
            bytes.removeSubrange(0...index)
            if bytes.count == 5, bytes[2] == UInt8(ascii: ":") { bytes.remove(at: 2) }
            guard bytes.count == 4, let hours = number(0, 2), let minutes = number(2, 2) else { return nil }
            offset = sign * (hours * 3600 + minutes * 60)
        default:
            return nil
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Double(seconds) + fraction
    }

    /// Howard Hinnant's days-from-civil: proleptic Gregorian date to days since 1970-01-01.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
