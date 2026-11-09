import Foundation

public enum JSONLines {
    /// Complete newline-terminated lines in `data` (without the terminator, empty lines dropped) and
    /// the number of bytes they span. A trailing partial line is left for the next read.
    public static func complete(in data: Data) -> (lines: [Data], consumed: Int) {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0) }
        var lines: [Data] = []
        var start = data.startIndex
        while start <= lastNewline {
            let end = data[start...lastNewline].firstIndex(of: UInt8(ascii: "\n")) ?? lastNewline
            var lineEnd = end
            if lineEnd > start, data[lineEnd - 1] == UInt8(ascii: "\r") { lineEnd -= 1 }
            if lineEnd > start { lines.append(data[start..<lineEnd]) }
            start = end + 1
        }
        return (lines, lastNewline + 1 - data.startIndex)
    }
}
