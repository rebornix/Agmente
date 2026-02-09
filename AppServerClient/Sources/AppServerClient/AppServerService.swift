import Foundation

@MainActor
public protocol AppServerServiceDelegate: AnyObject {
    func appServerService(_ service: AppServerService, didReceiveNotification notification: JSONRPCNotification)
    func appServerService(_ service: AppServerService, didReceiveMessage message: AppServerMessage)
    func appServerService(_ service: AppServerService, willSend request: JSONRPCRequest)
    func appServerService(_ service: AppServerService, didChangeState state: AppServerConnectionState)
    func appServerService(_ service: AppServerService, didEncounterError error: Error)
}

public final class AppServerService {
    private let client: AppServerClient
    private let idSequence = RequestIDSequence()
    private let pendingRequests = PendingRequestStore()
    private let includeJSONRPCHeader: Bool

    public weak var delegate: AppServerServiceDelegate?

    public init(client: AppServerClient, includeJSONRPCHeader: Bool = false) {
        self.client = client
        self.includeJSONRPCHeader = includeJSONRPCHeader
        self.client.delegate = self
    }

    public func connect() async throws {
        try await client.connect()
    }

    public func disconnect() async {
        await pendingRequests.failAll(with: AppServerServiceError.disconnected)
        await client.disconnect()
    }

    public func sendMessage(_ message: AppServerMessage) async throws {
        try await client.send(message)
    }

    public func setWithoutEscapingSlashesEnabled(_ enabled: Bool) {
        client.setWithoutEscapingSlashesEnabled(enabled)
    }

    public func initialize(_ payload: AppServerInitializePayload) async throws -> JSONRPCResponse {
        try await sendRequest(method: AppServerMethods.initialize, params: payload.params())
    }

    public func sendInitialized() async throws {
        let notification = JSONRPCNotification(method: AppServerMethods.initialized, includeJSONRPC: includeJSONRPCHeader)
        try await sendMessage(.notification(notification))
    }

    public func startThread(_ payload: AppServerThreadStartPayload) async throws -> JSONRPCResponse {
        try await sendRequest(method: AppServerMethods.threadStart, params: payload.params())
    }

    public func resumeThread(_ payload: AppServerThreadResumePayload) async throws -> JSONRPCResponse {
        try await sendRequest(method: AppServerMethods.threadResume, params: payload.params())
    }

    public func listThreads(_ payload: AppServerThreadListPayload = .init()) async throws -> JSONRPCResponse {
        try await sendRequest(method: AppServerMethods.threadList, params: payload.params())
    }

    public func archiveThread(_ payload: AppServerThreadArchivePayload) async throws -> JSONRPCResponse {
        try await sendRequest(method: AppServerMethods.threadArchive, params: payload.params())
    }

    public func startTurn(_ payload: AppServerTurnStartPayload) async throws -> JSONRPCResponse {
        try await sendRequest(method: AppServerMethods.turnStart, params: payload.params())
    }

    public func interruptTurn(_ payload: AppServerTurnInterruptPayload) async throws -> JSONRPCResponse {
        try await sendRequest(method: AppServerMethods.turnInterrupt, params: payload.params())
    }

    public func startReview(_ payload: AppServerReviewStartPayload) async throws -> JSONRPCResponse {
        try await sendRequest(method: AppServerMethods.reviewStart, params: payload.params())
    }

    public func execCommand(_ payload: AppServerCommandExecPayload) async throws -> JSONRPCResponse {
        try await sendRequest(method: AppServerMethods.commandExec, params: payload.params())
    }

    public func listModels(_ payload: AppServerModelListPayload = .init()) async throws -> JSONRPCResponse {
        try await sendRequest(method: AppServerMethods.modelList, params: payload.params())
    }

    public func listSkills(_ payload: AppServerSkillsListPayload = .init()) async throws -> JSONRPCResponse {
        try await sendRequest(method: AppServerMethods.skillsList, params: payload.params())
    }

    public func readConfig(_ payload: AppServerConfigReadPayload = .init()) async throws -> JSONRPCResponse {
        try await sendRequest(method: AppServerMethods.configRead, params: payload.params())
    }

    public func writeConfigValue(_ payload: AppServerConfigValueWritePayload) async throws -> JSONRPCResponse {
        try await sendRequest(method: AppServerMethods.configValueWrite, params: payload.params())
    }

    public func batchWriteConfig(_ payload: AppServerConfigBatchWritePayload) async throws -> JSONRPCResponse {
        try await sendRequest(method: AppServerMethods.configBatchWrite, params: payload.params())
    }

    public func call(method: String, params: JSONValue? = nil) async throws -> JSONRPCResponse {
        try await sendRequest(method: method, params: params)
    }

    private func sendRequest(method: String, params: JSONValue?) async throws -> JSONRPCResponse {
        guard case .disconnected = client.state else {
            return try await sendPreparedRequest(method: method, params: params)
        }
        throw AppServerServiceError.disconnected
    }

    private func sendPreparedRequest(method: String, params: JSONValue?) async throws -> JSONRPCResponse {
        let id = await idSequence.next()
        let request = JSONRPCRequest(id: id, method: method, params: params, includeJSONRPC: includeJSONRPCHeader)
        await MainActor.run { delegate?.appServerService(self, willSend: request) }
        let message = AppServerMessage.request(request)
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await pendingRequests.storeContinuation(continuation, for: id)
                do {
                    try await client.send(message)
                } catch {
                    await pendingRequests.resume(id: id, with: .failure(error))
                }
            }
        }
    }
}

extension AppServerService: @unchecked Sendable {}

extension AppServerService: AppServerClientDelegate {
    public func appServerClient(_ client: AppServerClient, didChangeState state: AppServerConnectionState) {
        Task { @MainActor in delegate?.appServerService(self, didChangeState: state) }
        if case .disconnected = state {
            Task { await pendingRequests.failAll(with: AppServerServiceError.disconnected) }
        }
    }

    public func appServerClient(_ client: AppServerClient, didReceiveMessage message: AppServerMessage) {
        Task { @MainActor in delegate?.appServerService(self, didReceiveMessage: message) }
        switch message {
        case .notification(let notification):
            Task { @MainActor in delegate?.appServerService(self, didReceiveNotification: notification) }
        case .response(let response):
            Task { await pendingRequests.resume(id: response.id, with: .success(response)) }
        case .error(let error):
            if let id = error.id {
                Task { await pendingRequests.resume(id: id, with: .failure(AppServerServiceError.rpc(error))) }
            } else {
                Task { @MainActor in delegate?.appServerService(self, didEncounterError: AppServerServiceError.rpc(error)) }
            }
        case .request:
            break
        }
    }

    public func appServerClient(_ client: AppServerClient, didEncounterError error: Error) {
        Task { @MainActor in delegate?.appServerService(self, didEncounterError: error) }
    }
}

public enum AppServerServiceError: Error, Equatable {
    case disconnected
    case rpc(JSONRPCErrorResponse)
    case unsupportedMessage
}

private actor RequestIDSequence {
    private var counter: Int = 0

    func next() -> JSONRPCID {
        counter += 1
        return .int(counter)
    }
}

private actor PendingRequestStore {
    private var continuations: [JSONRPCID: CheckedContinuation<JSONRPCResponse, Error>] = [:]

    func storeContinuation(_ continuation: CheckedContinuation<JSONRPCResponse, Error>, for id: JSONRPCID) {
        continuations[id] = continuation
    }

    func resume(id: JSONRPCID, with result: Result<JSONRPCResponse, Error>) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    func failAll(with error: Error) {
        let pending = continuations
        continuations.removeAll()
        pending.values.forEach { $0.resume(throwing: error) }
    }
}