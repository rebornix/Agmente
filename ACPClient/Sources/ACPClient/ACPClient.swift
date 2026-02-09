import Foundation

public protocol ACPClientDelegate: AnyObject {
    func acpClient(_ client: ACPClient, didChangeState state: ACPConnectionState)
    func acpClient(_ client: ACPClient, didReceiveMessage message: ACPWireMessage)
    func acpClient(_ client: ACPClient, didEncounterError error: Error)
}

public final class ACPClient {
    public private(set) var state: ACPConnectionState = .disconnected {
        didSet { notifyStateChange(state) }
    }

    public weak var delegate: ACPClientDelegate?

    private let configuration: ACPClientConfiguration
    private let socketProvider: WebSocketProviding
    private var connection: WebSocketConnection?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private let logger: ACPLogger
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var buffer: Data = Data()

    public init(
        configuration: ACPClientConfiguration,
        socketProvider: WebSocketProviding = URLSessionWebSocketProvider(),
        logger: ACPLogger = NoOpLogger(),
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
            logger.info("ACPClient connected")
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

    public func send(_ message: ACPWireMessage) async throws {
        guard let connection else { throw ACPClientError.disconnected }
        let payload = try encoder.encode(message)
        guard var text = String(data: payload, encoding: .utf8) else {
            throw ACPClientError.encodingFailed
        }
        if configuration.appendNewline {
            text.append("\n")
        }
        logger.info("Sending message: \(text)")
        try await connection.send(text: text)
    }

    /// Toggle JSON encoding behavior for servers that can't deserialize strings containing escapes.
    ///
    /// Some ACP servers deserialize JSON-RPC fields like `method` as borrowed strings and fail when
    /// clients emit escaped forward slashes (e.g. `"session\\/list"`). Enabling this option forces
    /// `JSONEncoder` to avoid escaping `/`.
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
        guard let connection else { throw ACPClientError.disconnected }
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
        // If buffer is empty, try fast paths first
        if buffer.isEmpty {
            // 1. Attempt to decode as a single JSON-RPC message
            if let message = try? ACPMessageBridge.decodeMessage(from: data, decoder: decoder) {
                notifyMessage(message)
                return
            }

            // 2. Fallback: split newline-delimited payloads (common with stdio bridges)
            // Only proceed if ALL lines are valid messages, otherwise treat as fragmented/complex
            if let text = String(data: data, encoding: .utf8) {
                let lines = text
                    .split(separator: "\n")
                    .map(String.init)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                
                if lines.count > 1 {
                    var messages: [ACPWireMessage] = []
                    var allValid = true
                    
                    for line in lines {
                        guard let lineData = line.data(using: .utf8),
                              let message = try? ACPMessageBridge.decodeMessage(from: lineData, decoder: decoder) else {
                            allValid = false
                            break
                        }
                        messages.append(message)
                    }
                    
                    if allValid {
                        logger.info("Received \(messages.count) newline-delimited messages")
                        messages.forEach(notifyMessage)
                        return
                    }
                }
            }
        }

        // 3. Buffering fallback for fragmented or complex messages
        buffer.append(data)

        while true {
            guard let (messageData, remaining) = extractNextJSON(from: buffer) else {
                break
            }

            buffer = remaining

            if let message = try? ACPMessageBridge.decodeMessage(from: messageData, decoder: decoder) {
                notifyMessage(message)
            } else {
                logger.error("Failed to decode extracted JSON message: \(String(data: messageData, encoding: .utf8) ?? "nil")")
                notifyError(ACPClientError.decodingFailed)
            }
        }
    }

    private func extractNextJSON(from data: Data) -> (Data, Data)? {
        var depth = 0
        var insideString = false
        var escaped = false
        var foundStart = false
        var startIndex = 0

        for (index, byte) in data.enumerated() {
            if !foundStart {
                if byte == 0x7B { // {
                    foundStart = true
                    startIndex = index
                    depth = 1
                }
                continue
            }

            if escaped {
                escaped = false
            } else if insideString {
                if byte == 0x5C { // Backslash
                    escaped = true
                } else if byte == 0x22 { // Quote
                    insideString = false
                }
            } else {
                if byte == 0x22 { // Quote
                    insideString = true
                } else if byte == 0x7B { // {
                    depth += 1
                } else if byte == 0x7D { // }
                    depth -= 1
                    if depth == 0 {
                        let splitIndex = index + 1
                        let messageData = data.subdata(in: startIndex..<splitIndex)
                        let remainingData = data.subdata(in: splitIndex..<data.count)
                        return (messageData, remainingData)
                    }
                }
            }
        }
        return nil
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

    private func notifyStateChange(_ newState: ACPConnectionState) {
        let delegate = self.delegate
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.acpClient(self, didChangeState: newState)
        }
    }

    private func notifyMessage(_ message: ACPWireMessage) {
        let delegate = self.delegate
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.acpClient(self, didReceiveMessage: message)
        }
    }

    private func notifyError(_ error: Error) {
        let delegate = self.delegate
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.acpClient(self, didEncounterError: error)
        }
    }
}

extension ACPClient: @unchecked Sendable {}