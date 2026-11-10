import AgentKit
import Foundation

extension SecretStore {
    public func modelServerSecrets(for serverID: String) throws -> ModelServerSecrets {
        guard let json = try secret(service: KeychainService.modelServer, account: serverID),
              let secrets = try? JSONDecoder().decode(ModelServerSecrets.self, from: Data(json.utf8)) else {
            return ModelServerSecrets()
        }
        return secrets
    }

    public func setModelServerSecrets(_ secrets: ModelServerSecrets, for serverID: String) throws {
        guard !secrets.isEmpty, let data = try? JSONEncoder().encode(secrets) else {
            try deleteSecret(service: KeychainService.modelServer, account: serverID)
            return
        }
        try setSecret(String(decoding: data, as: UTF8.self), service: KeychainService.modelServer, account: serverID)
    }

    public func deleteModelServerSecrets(for serverID: String) throws {
        try deleteSecret(service: KeychainService.modelServer, account: serverID)
    }
}
