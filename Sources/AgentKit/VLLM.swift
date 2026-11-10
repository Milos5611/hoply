import Foundation

public struct PromSample: Sendable, Equatable {
    public var name: String
    public var labels: [String: String]
    public var value: Double
}

public enum PrometheusParser {
    public static func parse(_ text: String) -> [PromSample] {
        var samples: [PromSample] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let sample = parseLine(line) { samples.append(sample) }
        }
        return samples
    }

    static func parseLine(_ line: String) -> PromSample? {
        let chars = Array(line)
        var index = 0
        var name = ""
        while index < chars.count, chars[index] != "{", chars[index] != " ", chars[index] != "\t" {
            name.append(chars[index])
            index += 1
        }
        guard !name.isEmpty else { return nil }

        var labels: [String: String] = [:]
        if index < chars.count, chars[index] == "{" {
            index += 1
            while index < chars.count, chars[index] != "}" {
                while index < chars.count, chars[index] == "," || chars[index] == " " { index += 1 }
                if index < chars.count, chars[index] == "}" { break }
                var key = ""
                while index < chars.count, chars[index] != "=" {
                    key.append(chars[index])
                    index += 1
                }
                guard index + 1 < chars.count, chars[index + 1] == "\"" else { return nil }
                index += 2
                var value = ""
                while index < chars.count, chars[index] != "\"" {
                    if chars[index] == "\\", index + 1 < chars.count {
                        let escaped = chars[index + 1]
                        value.append(escaped == "n" ? "\n" : escaped)
                        index += 2
                    } else {
                        value.append(chars[index])
                        index += 1
                    }
                }
                guard index < chars.count else { return nil }
                index += 1
                labels[key.trimmingCharacters(in: .whitespaces)] = value
            }
            guard index < chars.count else { return nil }
            index += 1
        }

        let rest = String(chars[index...]).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = rest.first, let value = Double(first) else { return nil }
        return PromSample(name: name, labels: labels, value: value)
    }
}
