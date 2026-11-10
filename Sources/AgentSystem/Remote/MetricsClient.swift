import AgentKit
import Foundation

public struct MetricsClient: Sendable {
    public let endpoint: RemoteEndpoint
    private let secrets: any SecretStore
    private let service: String
    private let session: URLSession

    public init(endpoint: RemoteEndpoint, secrets: any SecretStore = Keychain(),
                service: String = KeychainService.sparkDash, configuration: URLSessionConfiguration = .ephemeral) {
        self.endpoint = endpoint
        self.secrets = secrets
        self.service = service
        self.session = URLSession(configuration: configuration)
    }

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

final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
