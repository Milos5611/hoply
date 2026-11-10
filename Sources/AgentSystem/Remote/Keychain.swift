import AgentKit
import Foundation
import Security
import Synchronization

/// Where secrets live. The app uses `Keychain`; tests and previews use `InMemorySecretStore`.
public protocol SecretStore: Sendable {
    func secret(service: String, account: String) throws -> String?
    func setSecret(_ secret: String, service: String, account: String) throws
    /// Deleting a missing item is not an error.
    func deleteSecret(service: String, account: String) throws
}

/// Generic-password services, named after the bundle id (`com.coolcraftcoders.hoply`). The account is the
/// endpoint's host.
public enum KeychainService {
    public static let sparkDash = "com.coolcraftcoders.hoply.sparkdash"
}

extension SecretStore {
    public func bearerToken(for endpoint: RemoteEndpoint, service: String = KeychainService.sparkDash) throws -> String? {
        try secret(service: service, account: endpoint.host)
    }

    /// A blank token deletes the saved one.
    public func setBearerToken(_ token: String, for endpoint: RemoteEndpoint,
                               service: String = KeychainService.sparkDash) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try deleteSecret(service: service, account: endpoint.host)
        } else {
            try setSecret(trimmed, service: service, account: endpoint.host)
        }
    }

    public func deleteBearerToken(for endpoint: RemoteEndpoint, service: String = KeychainService.sparkDash) throws {
        try deleteSecret(service: service, account: endpoint.host)
    }
}

/// Generic passwords in the login keychain. Not the data-protection keychain: that needs a keychain-access-group
/// entitlement, which an ad-hoc or self-signed build doesn't have.
public struct Keychain: SecretStore {
    public init() {}

    public func secret(service: String, account: String) throws -> String? {
        var query = Self.query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ secret: String, service: String, account: String) throws {
        let query = Self.query(service: service, account: account)
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Hoply (\(account))"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    public func deleteSecret(service: String, account: String) throws {
        let status = SecItemDelete(Self.query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

public struct KeychainError: Error, Equatable, LocalizedError {
    public var status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "Keychain: \(message)"
    }
}

public final class InMemorySecretStore: SecretStore {
    private struct Key: Hashable {
        var service: String
        var account: String
    }

    private let items = Mutex<[Key: String]>([:])

    public init(_ secrets: [(service: String, account: String, secret: String)] = []) {
        for entry in secrets {
            items.withLock { $0[Key(service: entry.service, account: entry.account)] = entry.secret }
        }
    }

    public func secret(service: String, account: String) throws -> String? {
        items.withLock { $0[Key(service: service, account: account)] }
    }

    public func setSecret(_ secret: String, service: String, account: String) throws {
        items.withLock { $0[Key(service: service, account: account)] = secret }
    }

    public func deleteSecret(service: String, account: String) throws {
        _ = items.withLock { $0.removeValue(forKey: Key(service: service, account: account)) }
    }
}
