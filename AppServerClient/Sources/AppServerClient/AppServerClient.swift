import Foundation

public protocol AppServerClientDelegate: AnyObject {
    func appServerClient(_ client: AppServerClient, didChangeState state: AppServerConnectionState)
    func appServerClient(_ client: AppServerClient, didReceiveMessage message: AppServerMessage)
    func appServerClient(_ client: AppServerClient, didEncounterError error: Error)
}

public final class AppServerClient {
    public private(set) var state: AppServerConnectionState = .disconnected {
        didSet { notifyStateChange(state) }
    }

    public weak var delegate: AppServerClientDelegate?

    private let configuration: AppServerClientConfiguration
    private let socketProvider: WebSocketProviding
    private var connection: WebSocketConnection?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private let logger: AppServerLogger
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: AppServerClientConfiguration,
        socketProvider: WebSocketProviding = URLSessionWebSocketProvider(),
        logger: AppServerLogger = AppServerNoOpLogger(),
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.configuration = configuration
        self.socketProvider = socketProvider
        self.logger = logger
        self.encoder = encoder
        self.decoder = decoder
    }

    deinit {
        receiveTask?.cancel()
        pingTask?.cancel()
    }

    public func connect() async throws {
        guard case .disconnected = state else { return }
        state = .connecting
        let headers = await authorizationHeaders()
        let connection = socketProvider.makeConnection(url: configuration.endpoint)
        self.connection = connection
        do {
            try await connection.connect(headers: headers)
            state = .connected
            startReceiveLoop(connection: connection)
            startHeartbeat(connection: connection)
            logger.info("AppServerClient connected")
        } catch {
            state = .failed(error)
            notifyError(error)
            throw error
        }
    }

    public func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        guard let connection else { return }
        await connection.close()
        self.connection = nil
        state = .disconnected
    }

    public func send(_ message: AppServerMessage) async throws {
        guard let connection else { throw AppServerClientError.disconnected }
        let payload = try encoder.encode(message)
        guard var text = String(data: payload, encoding: .utf8) else {
            throw AppServerClientError.encodingFailed
        }
        if configuration.appendNewline {
            text.append("\n")
        }
        logger.info("Sending message: \(text)")
        try await connection.send(text: text)
    }

    /// Toggle JSON encoding behavior for servers that can't deserialize strings containing escapes.
    public func setWithoutEscapingSlashesEnabled(_ enabled: Bool) {
        var formatting = encoder.outputFormatting
        if enabled {
            formatting.insert(.withoutEscapingSlashes)
        } else {
            formatting = formatting.subtracting(.withoutEscapingSlashes)
        }
        encoder.outputFormatting = formatting
    }

    /// Sends a WebSocket ping frame to verify the connection is still alive.
    public func ping() async throws {
        guard let connection else { throw AppServerClientError.disconnected }
        try await connection.ping()
    }

    private func startReceiveLoop(connection: WebSocketConnection) {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let event = try await connection.receive()
                    logger.info("WebSocket event: \(eventSummary(event))")
                    switch event {
                    case .text(let text):
                        guard let data = text.data(using: .utf8) else { continue }
                        handleIncomingData(data)
                    case .binary(let data):
                        handleIncomingData(data)
                    case .closed:
                        state = .disconnected
                        return
                    case .connected:
                        continue
                    }
                } catch {
                    if Task.isCancelled { return }
                    logger.error("Receive loop error: \(error)")
                    state = .failed(error)
                    notifyError(error)
                    return
                }
            }
        }
    }

    private func startHeartbeat(connection: WebSocketConnection) {
        pingTask?.cancel()
        guard let interval = configuration.pingInterval else { return }
        pingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await connection.ping()
                } catch {
                    logger.error("Ping failed: \(error)")
                    state = .failed(error)
                    notifyError(error)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func authorizationHeaders() async -> [String: String] {
        guard let tokenProvider = configuration.authTokenProvider else { return configuration.additionalHeaders }
        do {
            let token = try await tokenProvider()
            var headers = configuration.additionalHeaders
            headers["Authorization"] = "Bearer \(token)"
            return headers
        } catch {
            logger.error("Failed to load auth token: \(error)")
            return configuration.additionalHeaders
        }
    }

    private func handleIncomingData(_ data: Data) {
        if let message = try? decoder.decode(AppServerMessage.self, from: data) {
            notifyMessage(message)
            return
        }

        if let text = String(data: data, encoding: .utf8) {
            logger.info("Received text: \(text)")
            let lines = text
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if lines.count > 1 {
                for line in lines {
                    guard let lineData = line.data(using: .utf8) else { continue }
                    if let message = try? decoder.decode(AppServerMessage.self, from: lineData) {
                        notifyMessage(message)
                    } else {
                        logger.error("Failed to decode message line: \(line)")
                        notifyError(AppServerClientError.decodingFailed)
                    }
                }
                return
            }
        }

        logger.error("Failed to decode message payload")
        notifyError(AppServerClientError.decodingFailed)
    }

    private func eventSummary(_ event: WebSocketEvent) -> String {
        switch event {
        case .connected:
            return "connected"
        case .closed(let reason):
            return "closed code=\(reason.code) reason=\(reason.reason ?? "")"
        case .text(let text):
            return "text len=\(text.count)"
        case .binary(let data):
            return "binary len=\(data.count)"
        }
    }

    private func notifyStateChange(_ newState: AppServerConnectionState) {
        let delegate = self.delegate
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.appServerClient(self, didChangeState: newState)
        }
    }

    private func notifyMessage(_ message: AppServerMessage) {
        let delegate = self.delegate
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.appServerClient(self, didReceiveMessage: message)
        }
    }

    private func notifyError(_ error: Error) {
        let delegate = self.delegate
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.appServerClient(self, didEncounterError: error)
        }
    }
}

extension AppServerClient: @unchecked Sendable {}