import AgentKit
import Foundation

/// Fetches JSON from a remote endpoint (sparkDash) with its Bearer token from the Keychain. Redirects are
/// refused rather than followed, so a login page in front of the service surfaces as a clear error and the
/// Authorization header never travels to another host. Returns the raw body; decoding happens elsewhere.
public struct MetricsClient: Sendable {
    public let endpoint: RemoteEndpoint
    private let secrets: any SecretStore
    private let service: String
    private let session: URLSession

    /// Ephemeral: no cookies, cache or credentials are kept between launches.
    public init(endpoint: RemoteEndpoint, secrets: any SecretStore = Keychain(),
                service: String = KeychainService.sparkDash, configuration: URLSessionConfiguration = .ephemeral) {
        self.endpoint = endpoint
        self.secrets = secrets
        self.service = service
        self.session = URLSession(configuration: configuration)
    }

    /// `path` is relative to the endpoint, e.g. `SparkDash.sparkPath("zgx-ff24", "metrics")`. Throws `RemoteError`.
    public func fetch(_ path: String, timeout: TimeInterval = 10) async throws -> Data {
        let token: String?
        do {
            token = try secrets.bearerToken(for: endpoint, service: service)
        } catch {
            throw RemoteError(.transport(error.localizedDescription), endpoint: endpoint.name)
        }
        guard let token, !token.isEmpty else { throw RemoteError(.missingToken, endpoint: endpoint.name) }
        let request = try endpoint.request(path: path, credentials: RemoteCredentials(bearerToken: token),
                                           timeout: timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: RedirectRefusal())
        } catch let error as URLError {
            throw RemoteError(.transport(error.localizedDescription), endpoint: endpoint.name)
        }
        return try endpoint.classify(response, body: data).get()
    }
}

/// Answering a redirect with nil completes the task with the 3xx response itself.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
