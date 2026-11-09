import Foundation

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    /// Path without the query string.
    public var path: String
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var reason: String
    public var contentType: String?
    public var body: Data

    public static func json(_ text: String = "{}") -> HTTPResponse {
        HTTPResponse(status: 200, reason: "OK", contentType: "application/json", body: Data(text.utf8))
    }

    public static var protobufOK: HTTPResponse {
        HTTPResponse(status: 200, reason: "OK", contentType: "application/x-protobuf", body: Data())
    }

    public static func text(_ text: String, status: Int = 200, reason: String = "OK") -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    public static func badRequest(_ message: String) -> HTTPResponse {
        text(message, status: 400, reason: "Bad Request")
    }

    public static var notFound: HTTPResponse {
        text("Not found", status: 404, reason: "Not Found")
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

/// Incremental HTTP/1.1 request parser. Supports Content-Length and chunked bodies
/// (the official OpenTelemetry JS exporters send chunked bodies with no Content-Length).
public enum HTTPRequestParser {
    public enum Result: Equatable {
        case incomplete(expectsContinue: Bool)
        case complete(HTTPRequest)
        case invalid(String)
    }

    public static let maxHeaderBytes = 64 * 1024
    public static let maxBodyBytes = 32 * 1024 * 1024

    public static func parse(_ buffer: Data) -> Result {
        let bytes = [UInt8](buffer)
        guard let headerEnd = find(bytes, [13, 10, 13, 10], from: 0) else {
            return bytes.count > maxHeaderBytes ? .invalid("Headers too large") : .incomplete(expectsContinue: false)
        }
        let head = String(decoding: bytes[0..<headerEnd], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid("Empty request") }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid("Bad request line") }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let expectsContinue = headers["expect"]?.lowercased() == "100-continue"
        let bodyStart = headerEnd + 4

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch decodeChunked(bytes, from: bodyStart) {
            case .complete(let body):
                return .complete(HTTPRequest(method: method, path: path, headers: headers, body: Data(body)))
            case .incomplete:
                return .incomplete(expectsContinue: expectsContinue)
            case .invalid(let reason):
                return .invalid(reason)
            }
        }

        let lengthText = headers["content-length"] ?? "0"
        guard let length = Int(lengthText), length >= 0 else { return .invalid("Bad Content-Length") }
        guard length <= maxBodyBytes else { return .invalid("Body too large") }
        guard bytes.count - bodyStart >= length else { return .incomplete(expectsContinue: expectsContinue) }
        let body = Data(bytes[bodyStart..<(bodyStart + length)])
        return .complete(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }

    enum ChunkResult {
        case complete([UInt8])
        case incomplete
        case invalid(String)
    }

    static func decodeChunked(_ bytes: [UInt8], from start: Int) -> ChunkResult {
        var index = start
        var body: [UInt8] = []
        while true {
            guard let lineEnd = find(bytes, [13, 10], from: index) else { return .incomplete }
            let sizeLine = String(decoding: bytes[index..<lineEnd], as: UTF8.self)
            let hex = sizeLine.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(hex, radix: 16), size >= 0 else { return .invalid("Bad chunk size") }
            index = lineEnd + 2
            if size == 0 {
                // Optional trailers, then an empty line.
                guard let end = find(bytes, [13, 10], from: index) else { return .incomplete }
                if end == index { return .complete(body) }
                return find(bytes, [13, 10, 13, 10], from: index) == nil ? .incomplete : .complete(body)
            }
            guard body.count + size <= maxBodyBytes else { return .invalid("Body too large") }
            guard bytes.count >= index + size + 2 else { return .incomplete }
            body.append(contentsOf: bytes[index..<(index + size)])
            index += size + 2
        }
    }

    static func find(_ haystack: [UInt8], _ needle: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count, start >= 0 else { return nil }
        var index = start
        while index <= haystack.count - needle.count {
            if haystack[index] == needle[0] {
                var matches = true
                for offset in 1..<needle.count where haystack[index + offset] != needle[offset] {
                    matches = false
                    break
                }
                if matches { return index }
            }
            index += 1
        }
        return nil
    }
}
