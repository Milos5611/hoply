import Foundation
import Security
import os

public protocol SecretStore: Sendable {
    func secret(service: String, account: String) throws -> String?
    func setSecret(_ secret: String, service: String, account: String) throws
    func deleteSecret(service: String, account: String) throws
}

public enum KeychainService {
    public static let modelServer = "com.coolcraftcoders.hoply.model-server"
}

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

    private let items = OSAllocatedUnfairLock<[Key: String]>(initialState: [:])

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
