import AgentKit
import AgentSystem
import Foundation

extension AppModel {
    func connect(_ agent: ConnectableAgent) {
        setUp([agent], connecting: true, askingForHome: false)
    }

    func connect(_ agents: [ConnectableAgent]) {
        if agents.count == 1 { connect(agents[0]) } else { connectAll(agents) }
    }

    func connectAll(_ agents: [ConnectableAgent]? = nil, showingResult: Bool = false) {
        setUp(agents ?? connections.connectable, connecting: true, askingForHome: true, showingResult: showingResult)
    }

    func disconnect(_ agent: ConnectableAgent) {
        setUp([agent], connecting: false, askingForHome: false)
    }

    func grantFolderAccess(_ folder: AgentFolder) {
        guard isLive, connections.begin([]) else { return }
        Task {
            await grantAccess(folder)
            connections.end()
        }
    }

    // Grants are kept per folder, so one home grant can sit under several folders: Remove takes away every grant
    // that still covers this folder, or it would read as allowed again at once.
    func revokeFolderAccess(_ folder: AgentFolder) {
        guard isLive, !connections.isBusy else { return }
        let grants = FolderGrants.shared
        let directory = connections.connector.configDirectory(for: folder.agent)
        let before = grants.access(settings: settings)
        var removed: [String] = []
        for _ in AgentFolder.allCases {
            guard case .granted(let path) = grants.access(for: folder, at: directory) else { break }
            removed.append(path)
            for grant in grants.grants where grant.path == path { grants.revoke(grant.folder) }
        }
        let after = grants.access(settings: settings)
        let others = AgentFolder.allCases.filter { other in
            other != folder && before[other]?.allowsReading == true && after[other]?.allowsReading == false
        }
        connections.note(FolderAccessText.removedNotice(removed, others: others), for: folder)
        for other in others { connections.note(nil, for: other) }
        foldersChanged()
    }

    private struct FolderRequest {
        var folder: AgentFolder
        var expected: String
        var message: String
        var wrongPick: (String) -> AgentConnections.Notice
    }

    private func setUp(_ agents: [ConnectableAgent], connecting: Bool, askingForHome: Bool,
                       showingResult: Bool = false) {
        guard isLive, !agents.isEmpty, connections.begin(agents) else { return }
        Task {
            let returnTo = showingSettings
            let (asked, cancelled) = await run(agents, connecting: connecting, askingForHome: askingForHome)
            await connections.reload()
            connections.end()
            let showsResult = showingResult && !cancelled
            if asked {
                reopenPanel(settings: returnTo || showsResult)
            } else if showsResult {
                showingSettings = true
            }
        }
    }

    private func run(_ agents: [ConnectableAgent], connecting: Bool,
                     askingForHome: Bool) async -> (asked: Bool, cancelled: Bool) {
        var asked = false
        var leftAsking: Set<ConnectableAgent> = []
        if askingForHome {
            let problems = await connections.accessProblems(for: agents)
            let needing = agents.filter { agent in
                if case .needsFolderAccess? = problems[agent]?.kind { true } else { false }
            }
            if !needing.isEmpty {
                asked = true
                guard let covered = await allowHome(for: needing) else { return (asked, true) }
                leftAsking = Set(needing).subtracting(covered)
            }
        }
        for agent in agents where !leftAsking.contains(agent) {
            var result: Result<ConnectOutcome, AgentConnectorError>?
            result = await connections.attempt(agent, connecting: connecting)
            // The answer may uncover the next problem: a settings file that links outside the folder just allowed.
            for _ in 0..<2 {
                guard case .failure(let error)? = result, let request = request(for: error, agent: agent) else { break }
                if askingForHome, case .needsFolderAccess = error.kind { break }
                asked = true
                guard await allow(request, for: agent) else {
                    result = nil
                    break
                }
                result = await connections.attempt(agent, connecting: connecting)
            }
            if let result { connections.finish(agent, result, connecting: connecting) }
        }
        return (asked, false)
    }

    private func request(for error: AgentConnectorError, agent: ConnectableAgent) -> FolderRequest? {
        switch error.kind {
        case .needsFolderAccess(let folder):
            let expected = connections.connector.configDirectory(for: agent)
            return FolderRequest(folder: folder, expected: expected,
                                 message: FolderAccessText.panelMessage(folder, expected: expected)) { picked in
                FolderAccessText.wrongPick(folder, picked: picked, expected: expected)
            }
        case .linkOutsideGrant(let folder, let target, let allow):
            return FolderRequest(folder: folder, expected: allow, message: error.message) { picked in
                FolderAccessText.wrongLinkPick(picked: picked, path: error.path, target: target, allow: allow)
            }
        case .unreadable, .writeFailed:
            return nil
        }
    }

    private func allow(_ request: FolderRequest, for agent: ConnectableAgent) async -> Bool {
        guard let picked = await AgentSetupPanels.chooseFolder(at: request.expected, message: request.message) else {
            return false
        }
        guard FolderAccessText.pick(picked.path, expected: request.expected) != .other else {
            connections.note(request.wrongPick(picked.path), for: agent)
            return false
        }
        guard grant(picked, for: request.folder, noting: agent) else { return false }
        foldersChanged()
        return true
    }

    private func allowHome(for agents: [ConnectableAgent]) async -> [ConnectableAgent]? {
        let connector = connections.connector
        let message = FolderAccessText.homeMessage(agents.map(connector.configDirectory(for:)))
        guard let picked = await AgentSetupPanels.chooseFolder(at: UserHome.path, message: message) else { return nil }
        var covered: [ConnectableAgent] = []
        for agent in agents {
            let directory = connector.configDirectory(for: agent)
            guard FolderAccessText.pick(picked.path, expected: directory) != .other else {
                connections.note(FolderAccessText.outsidePick(agent, picked: picked.path, directory: directory),
                                 for: agent)
                continue
            }
            if grant(picked, for: agent.folder, noting: agent) { covered.append(agent) }
        }
        if !covered.isEmpty { foldersChanged() }
        return covered
    }

    private func grant(_ picked: URL, for folder: AgentFolder, noting agent: ConnectableAgent) -> Bool {
        do {
            try FolderGrants.shared.grant(picked, for: folder)
            return true
        } catch {
            connections.note(FolderAccessText.grantFailed(picked.path, error), for: agent)
            return false
        }
    }

    private func grantAccess(_ folder: AgentFolder) async {
        let returnTo = showingSettings
        let expected = connections.connector.configDirectory(for: folder.agent)
        let message = FolderAccessText.panelMessage(folder, expected: expected)
        let picked = await AgentSetupPanels.chooseFolder(at: expected, message: message)
        reopenPanel(settings: returnTo)
        guard let picked else { return }
        let pick = FolderAccessText.pick(picked.path, expected: expected)
        guard pick != .other else {
            connections.note(FolderAccessText.wrongPick(folder, picked: picked.path, expected: expected), for: folder)
            return
        }
        do {
            try FolderGrants.shared.grant(picked, for: folder)
        } catch {
            connections.note(FolderAccessText.grantFailed(picked.path, error), for: folder)
            return
        }
        connections.note(pick == .covering ? FolderAccessText.coveringPick(picked.path, expected: expected) : nil,
                         for: folder)
        foldersChanged()
    }

    private func foldersChanged() {
        history.reopen(LedgerConfiguration(settings: settings))
        connections.refresh()
        iCloudLink.changed()
    }

    private func reopenPanel(settings: Bool) {
        if settings { openSettings() } else { openPanel() }
    }
}
