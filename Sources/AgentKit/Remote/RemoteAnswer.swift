import Foundation

public struct RemoteAnswer: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case decide
        case reply
        case done
        case away
        case launch
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public enum Decision: String, Codable, Sendable {
        case allow
        case deny
        case unknown

        public init(_ decision: ApprovalDecision) {
            self = decision == .allow ? .allow : .deny
        }

        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        public var approval: ApprovalDecision? {
            switch self {
            case .allow: .allow
            case .deny: .deny
            case .unknown: nil
            }
        }
    }

    public var id: String
    public var requestID: String?
    public var device: String?
    public var kind: Kind
    public var decision: Decision?
    public var text: String?
    public var on: Bool?
    public var agent: String?
    public var projectID: String?
    public var session: String?
    public var createdAt: Date

    public init(id: String = UUID().uuidString, requestID: String? = nil, device: String? = nil, kind: Kind,
                decision: Decision? = nil, text: String? = nil, on: Bool? = nil, agent: String? = nil,
                projectID: String? = nil, session: String? = nil, createdAt: Date) {
        self.id = id
        self.requestID = requestID
        self.device = device
        self.kind = kind
        self.decision = decision
        self.text = text
        self.on = on
        self.agent = agent
        self.projectID = projectID
        self.session = session
        self.createdAt = createdAt
    }

    public static func decide(_ decision: ApprovalDecision, to request: RemoteRequest,
                              at time: Date = Date()) -> RemoteAnswer {
        RemoteAnswer(requestID: request.id, device: request.device, kind: .decide, decision: Decision(decision),
                     createdAt: time)
    }

    public static func reply(_ text: String, to request: RemoteRequest, at time: Date = Date()) -> RemoteAnswer {
        RemoteAnswer(requestID: request.id, device: request.device, kind: .reply, text: text, createdAt: time)
    }

    public static func done(_ request: RemoteRequest, at time: Date = Date()) -> RemoteAnswer {
        RemoteAnswer(requestID: request.id, device: request.device, kind: .done, createdAt: time)
    }

    public static func away(_ on: Bool, device: String?, at time: Date = Date()) -> RemoteAnswer {
        RemoteAnswer(device: device, kind: .away, on: on, createdAt: time)
    }

    public static func launch(_ agent: String, projectID: String, session: String? = nil, prompt: String,
                              device: String, at time: Date = Date()) -> RemoteAnswer {
        RemoteAnswer(device: device, kind: .launch, text: prompt, agent: agent, projectID: projectID, session: session,
                     createdAt: time)
    }
}

public enum RemoteAction: Sendable, Equatable {
    case decide(id: String, ApprovalDecision)
    case reply(id: String, text: String)
    case finish(id: String)
    case setAway(Bool)
}

public struct RemoteResolution: Sendable, Equatable {
    public var actions: [RemoteAction]
    public var acknowledged: [String]
    public var launches: [RemoteLaunchDecision]

    public init(actions: [RemoteAction] = [], acknowledged: [String] = [], launches: [RemoteLaunchDecision] = []) {
        self.actions = actions
        self.acknowledged = acknowledged
        self.launches = launches
    }
}

public enum RemoteAnswers {
    // Phone and Mac clocks differ a little; an answer can't really predate the request it answers.
    public static let clockTolerance: TimeInterval = 60
    public static let foreignLifetime: TimeInterval = 24 * 3600
    public static let launchLifetime: TimeInterval = 600

    public static func resolve(_ answers: [RemoteAnswer], approvals: [ApprovalRequest], replies: [TurnReplyRequest],
                               device: String, handled: Set<String> = [], awaySetAt: Date? = nil,
                               launch catalog: LaunchCatalog? = nil, edition: Edition = .current,
                               now: Date) -> RemoteResolution {
        let catalog = edition.offersPhoneLaunch ? catalog : nil
        var openApprovals = Dictionary(approvals.map { ($0.id, $0.received) }, uniquingKeysWith: { first, _ in first })
        var openReplies = Dictionary(replies.map { ($0.id, $0.received) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var resumed: Set<SessionKey> = []
        var result = RemoteResolution()
        let ordered = answers.enumerated()
            .sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }
            .map(\.element)
        func fresh(_ answer: RemoteAnswer, _ received: Date) -> Bool {
            answer.createdAt >= received.addingTimeInterval(-clockTolerance)
        }
        for answer in ordered where seen.insert(answer.id).inserted {
            // Another Mac on the same Apple ID applies and deletes its own answers.
            if let target = answer.device, target != device {
                if now.timeIntervalSince(answer.createdAt) > foreignLifetime { result.acknowledged.append(answer.id) }
                continue
            }
            result.acknowledged.append(answer.id)
            guard !handled.contains(answer.id) else { continue }
            switch answer.kind {
            case .away:
                guard let on = answer.on, answer.createdAt >= (awaySetAt ?? .distantPast) else { continue }
                result.actions.append(.setAway(on))
                if !on { openReplies.removeAll() }
            case .decide:
                guard let id = answer.requestID, let received = openApprovals[id], fresh(answer, received),
                      let decision = answer.decision?.approval else { continue }
                result.actions.append(.decide(id: id, decision))
                openApprovals[id] = nil
            case .reply:
                guard let id = answer.requestID, let received = openReplies[id], fresh(answer, received),
                      let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                else { continue }
                result.actions.append(.reply(id: id, text: text))
                openReplies[id] = nil
            case .done:
                guard let id = answer.requestID, let received = openReplies[id], fresh(answer, received)
                else { continue }
                result.actions.append(.finish(id: id))
                openReplies[id] = nil
            case .launch:
                result.launches.append(launch(answer, catalog: catalog, resumed: &resumed, now: now))
            case .unknown:
                continue
            }
        }
        return result
    }

    private static func launch(_ answer: RemoteAnswer, catalog: LaunchCatalog?, resumed: inout Set<SessionKey>,
                               now: Date) -> RemoteLaunchDecision {
        func refuse(_ reason: RemoteLaunch.Reason) -> RemoteLaunchDecision {
            .refuse(.refused(answer.id, reason, at: now))
        }
        guard let catalog else { return refuse(.disabled) }
        guard answer.device != nil else { return refuse(.noDevice) }
        guard now.timeIntervalSince(answer.createdAt) <= launchLifetime else { return refuse(.expired) }
        guard let prompt = LaunchScript.normalizedPrompt(answer.text) else { return refuse(.emptyPrompt) }
        guard !LaunchScript.isShellMode(prompt) else { return refuse(.shellMode) }
        guard prompt.count <= LaunchScript.maxPromptLength else { return refuse(.promptTooLong) }
        guard let source = answer.agent.flatMap(AgentSource.init(rawValue:)), catalog.available.contains(source) else {
            return refuse(.unsupportedAgent)
        }
        guard let project = catalog.project(id: answer.projectID) else { return refuse(.unknownProject) }
        let order: RemoteLaunchOrder?
        if let key = answer.session {
            guard let session = catalog.session(key: key), session.key.source == source,
                  session.projectID == project.id, !resumed.contains(session.key) else { return refuse(.unknownSession) }
            order = RemoteLaunchOrder(answerID: answer.id, source: source, sessionID: session.key.id,
                                      projectID: project.id, directory: session.cwd, prompt: prompt)
            if order != nil { resumed.insert(session.key) }
        } else {
            guard project.agents.contains(source), LaunchScript.canStart(source) else {
                return refuse(.unsupportedAgent)
            }
            order = RemoteLaunchOrder(answerID: answer.id, source: source, sessionID: nil, projectID: project.id,
                                      directory: project.root, prompt: prompt)
        }
        return order.map(RemoteLaunchDecision.start) ?? refuse(.launchFailed)
    }
}
