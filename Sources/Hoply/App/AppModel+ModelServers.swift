import AgentKit
import Foundation

extension AppModel {
    func beginAddingModelServer() {
        modelServers.editor = ModelServerEditor(ModelServer(), isNew: true)
        openDashboard(.localModel)
    }

    func beginEditingModelServer(_ id: String) {
        guard let server = settings.modelServer(id: id) else { return }
        let editor = ModelServerEditor(server, isNew: false)
        modelServers.editor = editor
        modelServers.select(id)
        openDashboard(.localModel)
        Task { editor.stored = await modelServers.storedSecrets(for: id) }
    }

    func showLocalModel(server id: String) {
        modelServers.select(id)
        openDashboard(.localModel)
    }

    func addModelServer(_ server: ModelServer) {
        var updated = settings
        guard updated.modelServer(id: server.id) == nil else { return }
        updated.modelServers.append(server)
        apply(updated)
        modelServers.select(server.id)
    }

    func removeModelServer(_ id: String) {
        var updated = settings
        updated.modelServers.removeAll { $0.id == id }
        apply(updated)
    }

    func setModelServerEnabled(_ id: String, _ enabled: Bool) {
        var updated = settings
        guard let index = updated.modelServers.firstIndex(where: { $0.id == id }) else { return }
        updated.modelServers[index].enabled = enabled
        apply(updated)
    }

    func setTreatedAsLocal(_ servedModel: String, _ local: Bool) {
        var updated = settings
        updated.localModelPatterns = PricingTable.treatingAsLocal(servedModel, local, patterns: updated.localModelPatterns)
        apply(updated)
    }

    func testModelServer(_ editor: ModelServerEditor) {
        guard editor.test != .running else { return }
        let server = editor.server
        editor.test = .running
        Task {
            let probe = await modelServers.probe(server, typed: editor.typedSecrets)
            editor.test = probe.map { .done($0) } ?? .idle
        }
    }

    func saveModelServer(_ editor: ModelServerEditor) {
        let server = editor.server
        guard server.isConfigured, !editor.isSaving else { return }
        editor.isSaving = true
        editor.saveError = nil
        Task {
            defer { editor.isSaving = false }
            let secretsChanged: Bool
            do {
                secretsChanged = try await modelServers.save(server, typed: editor.typedSecrets)
            } catch {
                editor.saveError = "The sign-in details could not be saved to the Keychain: \(error.localizedDescription)"
                return
            }
            // Read at save time: the bell, a mute tile or another server may have changed settings meanwhile.
            var updated = settings
            if let index = updated.modelServers.firstIndex(where: { $0.id == server.id }) {
                updated.modelServers[index] = server
            } else {
                updated.modelServers.append(server)
            }
            apply(updated)
            if secretsChanged { modelServers.refresh(server.id) }
            if editor.isNew { modelServers.select(server.id) }
            if modelServers.editor === editor { modelServers.editor = nil }
        }
    }
}
