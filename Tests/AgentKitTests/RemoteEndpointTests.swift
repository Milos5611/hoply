import AgentKit
import Foundation
import XCTest

final class RemoteEndpointTests: XCTestCase {
    private let token = "tok-0123456789abcdef"
    private let endpoint = RemoteEndpoint(baseURL: "http://192.168.40.141:5555", name: "sparkDash")!

    func testBaseURLsAreSanitized() throws {
        XCTAssertEqual(RemoteEndpoint.sanitizedBaseURL(" http://192.168.40.141:5555/ "), "http://192.168.40.141:5555")
        XCTAssertEqual(RemoteEndpoint.sanitizedBaseURL("HTTPS://user:pw@zgx.example.com/dash/?token=abc#x"),
                       "https://zgx.example.com/dash")
        for invalid in ["", "zgx-ff24", "ftp://zgx.example.com", "http://", "/api/sparks"] {
            XCTAssertNil(RemoteEndpoint.sanitizedBaseURL(invalid), invalid)
            XCTAssertNil(RemoteEndpoint(baseURL: invalid, name: "sparkDash"), invalid)
        }
        let pasted = try XCTUnwrap(RemoteEndpoint(baseURL: "http://ZGX.local:5555?token=\(token)", name: "sparkDash"))
        XCTAssertFalse(pasted.baseURL.absoluteString.contains(token))
        XCTAssertEqual(pasted.host, "zgx.local", "the Keychain account")
    }

    func testTheBearerHeaderCarriesTheTokenAndTheURLNever() throws {
        let path = try XCTUnwrap(SparkDash.sparkPath("zgx-ff24", "metrics"))
        let request = try endpoint.request(path: path, credentials: RemoteCredentials(bearerToken: " \(token)\n"))
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.40.141:5555/api/sparks/zgx-ff24/metrics")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertFalse(request.url?.absoluteString.contains(token) ?? true)

        let queried = try endpoint.request(path: "/api/sparks/zgx-ff24/gpu-history?range=24h&token=\(token)&Access_Token=x",
                                           credentials: RemoteCredentials(bearerToken: token))
        XCTAssertEqual(queried.url?.absoluteString, "http://192.168.40.141:5555/api/sparks/zgx-ff24/gpu-history?range=24h")

        let prefixed = try XCTUnwrap(RemoteEndpoint(baseURL: "https://zgx.example.com/dash/", name: "sparkDash"))
        XCTAssertEqual(try prefixed.request(path: "api/fleet-energy", credentials: RemoteCredentials(bearerToken: token)).url?
            .absoluteString, "https://zgx.example.com/dash/api/fleet-energy")
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
        let json = Data(#"{"gpu":{"util":12}}"#.utf8)
        XCTAssertEqual(try endpoint.classify(status: 200, contentType: "application/json; charset=utf-8", location: nil,
                                             body: json).get(), json)

        let rejected = endpoint.classify(status: 401, contentType: "application/json; charset=utf-8", location: nil,
                                         body: Data(#"{"error":"Authentication required"}"#.utf8))
        XCTAssertEqual(rejected.failure?.kind, .tokenRejected(status: 401, message: "Authentication required"))
        XCTAssertEqual(rejected.failure?.errorDescription, "sparkDash rejected the token (HTTP 401)")
        XCTAssertEqual(endpoint.classify(status: 403, contentType: nil, location: nil, body: Data()).failure?.kind,
                       .tokenRejected(status: 403, message: nil))

        let page = Data("<!DOCTYPE html><html><body>sparkDash</body></html>".utf8)
        XCTAssertEqual(endpoint.classify(status: 200, contentType: "text/html; charset=utf-8", location: nil, body: page)
            .failure?.kind, .htmlPage(status: 200), "the dashboard's own page, not its API")
        XCTAssertEqual(endpoint.classify(status: 403, contentType: nil, location: nil, body: page).failure?.kind,
                       .htmlPage(status: 403), "a login page in front of the service")

        let redirect = endpoint.classify(status: 302, contentType: "text/html", location:
                                            "https://team.cloudflareaccess.com/cdn-cgi/access/login?redirect_url=x",
                                         body: Data())
        XCTAssertEqual(redirect.failure?.kind, .accessRequired(host: "team.cloudflareaccess.com"))
        XCTAssertEqual(redirect.failure?.errorDescription, "sparkDash is behind Cloudflare Access; add a service token")
        let elsewhere = endpoint.classify(status: 302, contentType: nil, location: "https://sso.example.com/login", body: Data())
        XCTAssertEqual(elsewhere.failure?.kind, .redirected(status: 302, host: "sso.example.com"))
        XCTAssertTrue(elsewhere.failure?.errorDescription?.contains("sso.example.com") ?? false)
        XCTAssertEqual(endpoint.classify(status: 301, contentType: nil, location: "/login", body: Data()).failure?.kind,
                       .redirected(status: 301, host: "192.168.40.141"))
        XCTAssertEqual(endpoint.classify(status: 503, contentType: nil, location: nil, body: Data()).failure?.kind,
                       .http(status: 503))

        let response = try XCTUnwrap(HTTPURLResponse(url: endpoint.baseURL, statusCode: 401, httpVersion: "HTTP/1.1",
                                                     headerFields: ["Content-Type": "application/json"]))
        XCTAssertEqual(endpoint.classify(response, body: Data(#"{"message":"nope"}"#.utf8)).failure?.kind,
                       .tokenRejected(status: 401, message: "nope"))
    }

    func testSparkDashRoutesAndSettings() throws {
        XCTAssertEqual(SparkDash.sparkPath("zgx-ff24", "metrics"), "/api/sparks/zgx-ff24/metrics")
        XCTAssertEqual(SparkDash.sparkPath(" zgx ff24 ", "/llm/daily"), "/api/sparks/zgx%20ff24/llm/daily")
        XCTAssertEqual(SparkDash.sparkPath("a/b", ""), "/api/sparks/a%2Fb")
        XCTAssertNil(SparkDash.sparkPath("  ", "metrics"))

        var settings = AppSettings()
        XCTAssertNil(SparkDash.endpoint(settings: settings), "blank = off")
        settings.sparkDashURL = "http://192.168.40.141:5555/"
        XCTAssertEqual(SparkDash.endpoint(settings: settings)?.baseURL.absoluteString, "http://192.168.40.141:5555")
        XCTAssertEqual(SparkDash.endpoint(settings: settings)?.name, "sparkDash")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
