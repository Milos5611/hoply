#if canImport(Network)
import Foundation
import Network

public final class HubServer: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case stopped
        case listening(UInt16)
        case failed(String)
    }

    public var onEvents: (@Sendable ([AgentEvent]) -> Void)?
    public var onUsage: (@Sendable ([UsageRecord]) -> Void)?
    public var onPrompts: (@Sendable ([PromptRecord]) -> Void)?
    public var onStatus: (@Sendable (Status) -> Void)?
    public var onNote: (@Sendable (String) -> Void)?
    public var onApproval: (@Sendable (ApprovalRequest, [AgentEvent]) -> Void)?
    public var onApprovalClosed: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "hoply.hub")
    private let router = HubRouter()
    private var listener: NWListener?
    private var holdsApprovals = false
    private var held: [String: HeldApproval] = [:]

    private struct HeldApproval {
        let connection: NWConnection
        let expiry: DispatchWorkItem
    }

    public init() {}

    public func start(port: UInt16) {
        queue.async { [weak self] in self?.startOnQueue(port: port) }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.releaseAll()
            self?.listener?.cancel()
            self?.listener = nil
            self?.onStatus?(.stopped)
        }
    }

    public func setHoldsApprovals(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            holdsApprovals = enabled
            if !enabled { releaseAll() }
        }
    }

    public func resolve(_ id: String, _ decision: ApprovalDecision) {
        queue.async { [weak self] in self?.finish(id, with: PermissionApproval.response(decision), notify: false) }
    }

    public func release(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        queue.async { [weak self] in
            for id in ids { self?.finish(id, with: PermissionApproval.response(nil), notify: false) }
        }
    }

    private func startOnQueue(port: UInt16) {
        listener?.cancel()
        listener = nil
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onStatus?(.failed("Invalid port \(port)"))
            return
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback interface only (127.0.0.1 and ::1): nothing on the network can reach this listener.
        parameters.requiredInterfaceType = .loopback
        do {
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    self?.onStatus?(.listening(port))
                case .failed(let error):
                    self?.onStatus?(.failed(HubServer.describe(error, port: port)))
                    listener?.cancel()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onStatus?(.failed(error.localizedDescription))
        }
    }

    private static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use"
        }
        return error.localizedDescription
    }

    private func accept(_ connection: NWConnection) {
        if case .hostPort(let host, _) = connection.endpoint, !HubServer.isLoopback(host) {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data(), sentContinue: false)
    }

    private static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || "\(address)".hasSuffix("127.0.0.1")
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    private func receive(on connection: NWConnection, buffer: Data, sentContinue: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data, !data.isEmpty { buffer.append(data) }

            switch HTTPRequestParser.parse(buffer) {
            case .complete(let request):
                let outcome = self.router.handle(request)
                if let approval = outcome.approval, self.holdsApprovals, let onApproval = self.onApproval {
                    self.hold(approval, on: connection)
                    onApproval(approval, outcome.events)
                    return
                }
                if !outcome.events.isEmpty { self.onEvents?(outcome.events) }
                if !outcome.usage.isEmpty { self.onUsage?(outcome.usage) }
                if !outcome.prompts.isEmpty { self.onPrompts?(outcome.prompts) }
                if let note = outcome.note { self.onNote?(note) }
                self.send(outcome.response, on: connection)
            case .incomplete(let expectsContinue):
                if error != nil || isComplete {
                    connection.cancel()
                    return
                }
                var continued = sentContinue
                if expectsContinue && !sentContinue {
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
                    continued = true
                }
                self.receive(on: connection, buffer: buffer, sentContinue: continued)
            case .invalid(let reason):
                self.onNote?("Rejected request: \(reason)")
                self.send(.badRequest(reason), on: connection)
            }
        }
    }

    private func hold(_ approval: ApprovalRequest, on connection: NWConnection) {
        let expiry = DispatchWorkItem { [weak self] in
            self?.finish(approval.id, with: PermissionApproval.response(nil), notify: true)
        }
        held[approval.id] = HeldApproval(connection: connection, expiry: expiry)
        queue.asyncAfter(deadline: .now() + PermissionApproval.holdLimit, execute: expiry)
        watchForClose(connection, id: approval.id)
    }

    // The hook's curl closes the socket when Claude Code cancels the hook; nothing is left to answer then.
    private func watchForClose(_ connection: NWConnection, id: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard let self, self.held[id] != nil else { return }
            if isComplete || error != nil {
                if let entry = self.held.removeValue(forKey: id) {
                    entry.expiry.cancel()
                    entry.connection.cancel()
                }
                self.onApprovalClosed?(id)
            } else {
                self.watchForClose(connection, id: id)
            }
        }
    }

    private func finish(_ id: String, with response: HTTPResponse, notify: Bool) {
        guard let entry = held.removeValue(forKey: id) else { return }
        entry.expiry.cancel()
        send(response, on: entry.connection)
        if notify { onApprovalClosed?(id) }
    }

    private func releaseAll() {
        for id in Array(held.keys) { finish(id, with: PermissionApproval.response(nil), notify: true) }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
#endif
