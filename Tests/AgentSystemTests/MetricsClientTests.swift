@testable import AgentSystem
import AgentKit
import Foundation
import Network
import Synchronization
import XCTest

/// A loopback HTTP server answering every request with one canned response, recording what it received.
private final class StubServer: Sendable {
    private final class Recorder: Sendable {
        let requests = Mutex<[String]>([])
    }

    private final class Once: Sendable {
        private let done = Mutex(false)

        func claim() -> Bool {
            done.withLock { done in
                defer { done = true }
                return !done
            }
        }
    }

    private let listener: NWListener
    private let received = Recorder()
    let port: UInt16

    var requests: [String] { received.requests.withLock { $0 } }

    init(response: String) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let received = self.received
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                received.requests.withLock { $0.append(String(decoding: data ?? Data(), as: UTF8.self)) }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                let value: Result<UInt16, Error>? = switch state {
                case .ready: .success(listener.port?.rawValue ?? 0)
                case .failed(let error): .failure(error)
                default: nil
                }
                guard let value, once.claim() else { return }
                continuation.resume(with: value)
            }
            listener.start(queue: .global())
        }
    }

    deinit { listener.cancel() }
}

final class MetricsClientTests: XCTestCase {
    private let token = "tok-0123456789abcdef"

    private func response(_ status: String, _ headers: [String], body: String = "") -> String {
        (["HTTP/1.1 \(status)", "Content-Length: \(body.utf8.count)", "Connection: close"] + headers)
            .joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    private func client(_ server: StubServer, secrets: InMemorySecretStore? = nil) throws -> MetricsClient {
        let endpoint = try XCTUnwrap(RemoteEndpoint(baseURL: "http://127.0.0.1:\(server.port)", name: "sparkDash"))
        let store = secrets ?? InMemorySecretStore([(KeychainService.sparkDash, "127.0.0.1", token)])
        return MetricsClient(endpoint: endpoint, secrets: store)
    }

    func testFetchSendsTheTokenAsABearerHeaderOnly() async throws {
        let body = #"{"gpu":{"utilization":12}}"#
        let server = try await StubServer(response: response("200 OK", ["Content-Type: application/json"], body: body))
        let data = try await client(server).fetch(try XCTUnwrap(SparkDash.sparkPath("zgx-ff24", "metrics")))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), body)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(request.hasPrefix("GET /api/sparks/zgx-ff24/metrics HTTP/1.1\r\n"), request)
        XCTAssertTrue(request.contains("\r\nAuthorization: Bearer \(token)\r\n") || request.contains("\r\nauthorization: Bearer \(token)\r\n"))
        XCTAssertEqual(request.components(separatedBy: token).count - 1, 1, "the token appears once, in the header")
    }

    func testRedirectsAreRefusedNotFollowed() async throws {
        let server = try await StubServer(response: response("302 Found", ["Location: /login?next=%2Fapi"]))
        do {
            _ = try await client(server).fetch("/api/fleet-energy")
            XCTFail("a redirect must not succeed")
        } catch let error as RemoteError {
            XCTAssertEqual(error.kind, .redirected(status: 302, host: "127.0.0.1"))
        }
        XCTAssertEqual(server.requests.count, 1, "the Location was never requested")
    }

    func testRejectedTokenAndHTMLPage() async throws {
        let rejected = try await StubServer(response: response("401 Unauthorized", ["Content-Type: application/json; charset=utf-8"],
                                                               body: #"{"error":"Authentication required"}"#))
        do {
            _ = try await client(rejected).fetch("/api/fleet-energy")
            XCTFail("401 must throw")
        } catch let error as RemoteError {
            XCTAssertEqual(error.kind, .tokenRejected(status: 401, message: "Authentication required"))
            XCTAssertEqual(error.errorDescription, "sparkDash rejected the token (HTTP 401)")
        }

        let page = try await StubServer(response: response("200 OK", ["Content-Type: text/html; charset=utf-8"],
                                                           body: "<!doctype html><title>sparkDash</title>"))
        do {
            _ = try await client(page).fetch("/gpu-history")
            XCTFail("HTML must throw")
        } catch let error as RemoteError {
            XCTAssertEqual(error.kind, .htmlPage(status: 200))
        }
    }

    func testNoTokenMeansNoRequest() async throws {
        let server = try await StubServer(response: response("200 OK", []))
        do {
            _ = try await client(server, secrets: InMemorySecretStore()).fetch("/api/fleet-energy")
            XCTFail("no token must throw")
        } catch let error as RemoteError {
            XCTAssertEqual(error.kind, .missingToken)
        }
        XCTAssertEqual(server.requests, [])
    }

    func testSecretStoreHelpersAndKeychainQuery() throws {
        let store = InMemorySecretStore()
        let endpoint = try XCTUnwrap(RemoteEndpoint(baseURL: "http://ZGX.local:5555", name: "sparkDash"))
        try store.setBearerToken("  \(token)\n", for: endpoint)
        XCTAssertEqual(try store.secret(service: "com.coolcraftcoders.hoply.sparkdash", account: "zgx.local"), token)
        XCTAssertEqual(try store.bearerToken(for: endpoint), token)
        try store.setBearerToken("", for: endpoint)
        XCTAssertNil(try store.bearerToken(for: endpoint), "a blank token deletes the saved one")
        try store.deleteBearerToken(for: endpoint)

        let query = Keychain.query(service: KeychainService.sparkDash, account: "zgx.local")
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.coolcraftcoders.hoply.sparkdash")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "zgx.local")
        XCTAssertNil(query[kSecAttrSynchronizable as String], "never synced to iCloud")
        XCTAssertNil(query[kSecUseDataProtectionKeychain as String])
    }
}
