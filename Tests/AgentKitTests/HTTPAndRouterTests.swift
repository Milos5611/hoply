@testable import AgentKit
import XCTest

final class HTTPRequestParserTests: XCTestCase {
    func testParsesChunkedRequestFromOpenTelemetryJSExporter() throws {
        let raw = try Fixture.data("http_chunked_request.bin")
        guard case .complete(let request) = HTTPRequestParser.parse(raw) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/logs")
        XCTAssertEqual(request.headers["content-type"], "application/json")
        let records = try OTLPDecoder.decode(path: request.path, body: request.body, encoding: .json)
        XCTAssertEqual(records.map(\.name), ["user_prompt"])
        XCTAssertEqual(records.first?["session.id"], .string("s-raw"))
    }

    func testChunkedRequestMissingTerminatorIsIncomplete() throws {
        let raw = try Fixture.data("http_chunked_request.bin")
        XCTAssertEqual(HTTPRequestParser.parse(raw.dropLast(5)), .incomplete(expectsContinue: false))
    }

    func testContentLengthBodyAndQueryString() {
        let raw = Data("POST /hooks/claude-code?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}".utf8)
        guard case .complete(let request) = HTTPRequestParser.parse(raw) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(request.path, "/hooks/claude-code")
        XCTAssertEqual(request.body, Data("{}".utf8))
    }

    func testExpectContinueIsReported() {
        let raw = Data("POST /hooks/copilot-cli HTTP/1.1\r\nContent-Length: 10\r\nExpect: 100-continue\r\n\r\n".utf8)
        XCTAssertEqual(HTTPRequestParser.parse(raw), .incomplete(expectsContinue: true))
    }

    func testHeadersWithoutTerminatorAreIncomplete() {
        XCTAssertEqual(HTTPRequestParser.parse(Data("POST /v1/logs HTTP/1.1\r\nHost: x".utf8)),
                       .incomplete(expectsContinue: false))
    }

    func testChunkExtensionsAndMultipleChunks() {
        let raw = Data("POST /v1/logs HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3;ext=1\r\nabc\r\n2\r\nde\r\n0\r\n\r\n".utf8)
        guard case .complete(let request) = HTTPRequestParser.parse(raw) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "abcde")
    }
}

final class HubRouterTests: XCTestCase {
    private let router = HubRouter()

    private func request(_ method: String, _ path: String, _ body: Data = Data(),
                         headers: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    func testHealth() {
        let outcome = router.handle(request("GET", "/health"))
        XCTAssertEqual(outcome.response.status, 200)
    }

    func testProtobufLogsProduceEventsAndProtobufResponse() throws {
        let body = try Fixture.data("claude_logs.pb")
        let outcome = router.handle(request("POST", "/v1/logs", body, headers: ["content-type": "application/x-protobuf"]))
        XCTAssertEqual(outcome.response.status, 200)
        XCTAssertEqual(outcome.response.contentType, "application/x-protobuf")
        XCTAssertEqual(outcome.events.count, 3)
    }

    func testJSONTracesWithoutContentTypeAreSniffed() throws {
        let body = try Fixture.data("copilot_spans.json")
        let outcome = router.handle(request("POST", "/v1/traces", body))
        XCTAssertEqual(outcome.response.contentType, "application/json")
        XCTAssertEqual(outcome.events.count, 2)
    }

    func testMetricsAreAcceptedButIgnored() {
        let outcome = router.handle(request("POST", "/v1/metrics", Data("{}".utf8),
                                            headers: ["content-type": "application/json"]))
        XCTAssertEqual(outcome.response.status, 200)
        XCTAssertTrue(outcome.events.isEmpty)
    }

    func testCompressedPayloadIsRejectedWithHint() {
        let outcome = router.handle(request("POST", "/v1/logs", Data([0x1F, 0x8B]),
                                            headers: ["content-encoding": "gzip"]))
        XCTAssertEqual(outcome.response.status, 415)
        XCTAssertNotNil(outcome.note)
    }

    func testCopilotHookUsesEventNameFromPath() throws {
        let payload = try XCTUnwrap(Fixture.hookPayloads("copilot_cli_hooks.json")["agentStop"])
        let body = try JSONSerialization.data(withJSONObject: payload)
        let outcome = router.handle(request("POST", "/hooks/copilot-cli/agentStop", body))
        XCTAssertEqual(outcome.response.status, 200)
        XCTAssertEqual(outcome.events.map(\.kind), [.turnFinished(nil)])
        XCTAssertEqual(outcome.events.first?.key, SessionKey(source: .copilotCLI, id: "cp-9"))
    }

    func testUnknownHookSourceIs404() {
        let outcome = router.handle(request("POST", "/hooks/nope", Data("{}".utf8)))
        XCTAssertEqual(outcome.response.status, 404)
    }

    func testResponseSerialization() {
        let text = String(decoding: HTTPResponse.json().serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{}"))
    }
}
