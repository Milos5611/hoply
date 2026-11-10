import AgentKit
import Foundation
import XCTest

final class RemoteEndpointTests: XCTestCase {
    private let token = "tok-0123456789abcdef"
    private let endpoint = RemoteEndpoint(baseURL: "http://192.168.40.141:8888", name: "Box")!

    func testBaseURLsAreSanitized() throws {
        XCTAssertEqual(RemoteEndpoint.sanitizedBaseURL(" http://192.168.40.141:8888/ "), "http://192.168.40.141:8888")
        XCTAssertEqual(RemoteEndpoint.sanitizedBaseURL("HTTPS://user:pw@zgx.example.com/llm/?token=abc#x"),
                       "https://zgx.example.com/llm")
        for invalid in ["", "zgx-ff24", "ftp://zgx.example.com", "http://", "/v1/models"] {
            XCTAssertNil(RemoteEndpoint.sanitizedBaseURL(invalid), invalid)
            XCTAssertNil(RemoteEndpoint(baseURL: invalid, name: "Box"), invalid)
        }
        let pasted = try XCTUnwrap(RemoteEndpoint(baseURL: "http://ZGX.local:8888?token=\(token)", name: "Box"))
        XCTAssertFalse(pasted.baseURL.absoluteString.contains(token))
        XCTAssertEqual(pasted.host, "zgx.local")
    }

    func testTheBearerHeaderCarriesTheTokenAndTheURLNever() throws {
        let request = try endpoint.request(path: "/v1/models", credentials: RemoteCredentials(bearerToken: " \(token)\n"))
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.40.141:8888/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertFalse(request.url?.absoluteString.contains(token) ?? true)

        let queried = try endpoint.request(path: "/api/ps?verbose=1&token=\(token)&Access_Token=x",
                                           credentials: RemoteCredentials(bearerToken: token))
        XCTAssertEqual(queried.url?.absoluteString, "http://192.168.40.141:8888/api/ps?verbose=1")

        let prefixed = try XCTUnwrap(RemoteEndpoint(baseURL: "https://zgx.example.com/llm/", name: "Box"))
        XCTAssertEqual(try prefixed.request(path: "v1/models", credentials: RemoteCredentials(bearerToken: token)).url?
            .absoluteString, "https://zgx.example.com/llm/v1/models")
    }

    func testBadTokensAreRefusedBeforeSending() {
        XCTAssertThrowsError(try endpoint.request(path: "/x", credentials: RemoteCredentials(bearerToken: "  "))) {
            XCTAssertEqual(($0 as? RemoteError)?.kind, .missingToken)
        }
        XCTAssertThrowsError(try endpoint.request(path: "/x", credentials: RemoteCredentials(bearerToken: "a\r\nX-Evil: 1"))) {
            XCTAssertEqual(($0 as? RemoteError)?.kind, .invalidToken)
        }
        XCTAssertNoThrow(try endpoint.request(path: "/x", credentials: RemoteCredentials()), "a token is optional per request")
    }

    func testExtraHeadersForLaterAccessTokens() throws {
        let credentials = RemoteCredentials(bearerToken: token, headers: ["CF-Access-Client-Id": "id.access",
                                                                          "CF-Access-Client-Secret": "s3cret"])
        let request = try endpoint.request(path: "/x", credentials: credentials)
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "id.access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertFalse(String(describing: credentials).contains(token))
        XCTAssertFalse(String(reflecting: credentials).contains("s3cret"))
    }

    func testClassification() throws {
        let json = Data(#"{"object":"list","data":[]}"#.utf8)
        XCTAssertEqual(try endpoint.classify(status: 200, contentType: "application/json; charset=utf-8", location: nil,
                                             body: json, auth: .bearer).get(), json)

        let rejected = endpoint.classify(status: 401, contentType: "application/json; charset=utf-8", location: nil,
                                         body: Data(#"{"error":"Authentication required"}"#.utf8), auth: .bearer)
        XCTAssertEqual(rejected.failure?.kind, .tokenRejected(status: 401, message: "Authentication required"))
        XCTAssertEqual(rejected.failure?.errorDescription, "Box rejected the token (HTTP 401)")
        XCTAssertEqual(endpoint.classify(status: 403, contentType: nil, location: nil, body: Data(), auth: .bearer)
            .failure?.kind, .tokenRejected(status: 403, message: nil))

        let page = Data("<!DOCTYPE html><html><body>Open WebUI</body></html>".utf8)
        XCTAssertEqual(endpoint.classify(status: 200, contentType: "text/html; charset=utf-8", location: nil, body: page,
                                         auth: .bearer).failure?.kind, .htmlPage(status: 200), "a web UI, not its API")
        XCTAssertEqual(endpoint.classify(status: 403, contentType: nil, location: nil, body: page, auth: .bearer)
            .failure?.kind, .htmlPage(status: 403), "a login page in front of the server")
        XCTAssertEqual(endpoint.classify(status: 403, contentType: nil, location: nil, body: page, auth: .headers)
            .failure?.kind, .tokenRejected(status: 403, message: nil))

        let redirect = endpoint.classify(status: 302, contentType: "text/html", location:
                                            "https://team.cloudflareaccess.com/cdn-cgi/access/login?redirect_url=x",
                                         body: Data(), auth: .bearer)
        XCTAssertEqual(redirect.failure?.kind, .accessRequired(host: "team.cloudflareaccess.com"))
        XCTAssertEqual(redirect.failure?.errorDescription, "Box is behind Cloudflare Access; add a service token")
        let elsewhere = endpoint.classify(status: 302, contentType: nil, location: "https://sso.example.com/login",
                                          body: Data(), auth: .bearer)
        XCTAssertEqual(elsewhere.failure?.kind, .redirected(status: 302, host: "sso.example.com"))
        XCTAssertTrue(elsewhere.failure?.errorDescription?.contains("sso.example.com") ?? false)
        XCTAssertEqual(endpoint.classify(status: 301, contentType: nil, location: "/login", body: Data(), auth: .bearer)
            .failure?.kind, .redirected(status: 301, host: "192.168.40.141"))
        XCTAssertEqual(endpoint.classify(status: 503, contentType: nil, location: nil, body: Data(), auth: .bearer)
            .failure?.kind, .http(status: 503))

        let response = try XCTUnwrap(HTTPURLResponse(url: endpoint.baseURL, statusCode: 401, httpVersion: "HTTP/1.1",
                                                     headerFields: ["Content-Type": "application/json"]))
        XCTAssertEqual(endpoint.classify(response, body: Data(#"{"message":"nope"}"#.utf8), auth: .bearer).failure?.kind,
                       .tokenRejected(status: 401, message: "nope"))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
