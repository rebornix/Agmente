import Foundation
import Network
import ACP

/// Delegate protocol for ACPClientManager events.
@MainActor
public protocol ACPClientManagerDelegate: AnyObject {
    /// Called when the connection state changes.
    func clientManager(_ manager: ACPClientManager, didChangeState state: ACPConnectionState)
    /// Called when network availability changes.
    func clientManager(_ manager: ACPClientManager, didChangeNetworkAvailability available: Bool)
    /// Called when a connection error occurs.
    func clientManager(_ manager: ACPClientManager, didEncounterError error: Error)
    /// Called to provide log messages for debugging.
    func clientManager(_ manager: ACPClientManager, didLog message: String)
    /// Called when the service is ready for use (connected).
    func clientManager(_ manager: ACPClientManager, didCreateService service: ACPService)
    /// Called when an ACP message is received.
    func clientManager(_ manager: ACPClientManager, didReceiveMessage message: ACPWireMessage)
    /// Called when a JSON-RPC notification is received.
    func clientManager(_ manager: ACPClientManager, didReceiveNotification notification: ACP.AnyMessage)
    /// Called before an ACP request is sent.
    func clientManager(_ manager: ACPClientManager, willSendRequest request: ACP.AnyRequest)
}

/// Default implementations for optional delegate methods.
public extension ACPClientManagerDelegate {
    func clientManager(_ manager: ACPClientManager, didReceiveMessage message: ACPWireMessage) {}
    func clientManager(_ manager: ACPClientManager, didReceiveNotification notification: ACP.AnyMessage) {}
    func clientManager(_ manager: ACPClientManager, willSendRequest request: ACP.AnyRequest) {}
}

/// Configuration for establishing a connection.
public struct ACPConnectionConfig: Sendable {
    public let endpoint: URL
    public let authToken: String?
    public let cloudflareAccessClientId: String?
    public let cloudflareAccessClientSecret: String?
    public let requiresUnescapedSlashes: Bool
    public let pingInterval: TimeInterval

    public init(
        endpoint: URL,
        authToken: String? = nil,
        cloudflareAccessClientId: String? = nil,
        cloudflareAccessClientSecret: String? = nil,
        requiresUnescapedSlashes: Bool = false,
        pingInterval: TimeInterval = 15
    ) {
        self.endpoint = endpoint
        self.authToken = authToken
        self.cloudflareAccessClientId = cloudflareAccessClientId
        self.cloudflareAccessClientSecret = cloudflareAccessClientSecret
        self.requiresUnescapedSlashes = requiresUnescapedSlashes
        self.pingInterval = pingInterval
    }
}

/// Manages ACPClient/ACPService lifecycle, reconnection, and network monitoring.
///
/// This class encapsulates all connection management logic:
/// - Connect/disconnect lifecycle
/// - Automatic reconnection with exponential backoff
/// - Network reachability monitoring
/// - Connection health checks
/// - Persistent client ID for session resumption
@MainActor
public final class ACPClientManager: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var connectionState: ACPConnectionState = .disconnected
    @Published public private(set) var isConnecting: Bool = false
    @Published public private(set) var isNetworkAvailable: Bool = true
    @Published public private(set) var lastConnectedAt: Date?
    @Published public private(set) var isInitialized: Bool = false
    @Published public private(set) var isInitializing: Bool = false

    // MARK: - Configuration

    /// Maximum number of automatic reconnection attempts before giving up.
    public var maxReconnectAttempts: Int = 3

    /// Base delay between reconnection attempts (doubles with each attempt).
    public var reconnectBaseDelay: TimeInterval = 1.0

    /// Timeout for health check pings.
    public var healthCheckTimeout: TimeInterval = 8.0
    /// Whether to automatically send initialize after connecting.
    public var shouldAutoInitialize: Bool = false
    /// Supplies the initialization payload for auto-initialize flows.
    public var initializationPayloadProvider: (() -> ACPInitializationPayload?)?

    // MARK: - Properties

    /// The active service instance, or nil if disconnected.
    public private(set) var service: ACPService?

    /// Persistent client ID sent with every WebSocket connection.
    /// Enables session resumption with compatible servers.
    public let clientId: String

    public weak var delegate: ACPClientManagerDelegate?

    // MARK: - Private State

    private var shouldAutoReconnect: Bool = false
    private var userInitiatedDisconnect: Bool = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts: Int = 0
    private var connectContinuation: CheckedContinuation<Bool, Never>?
    private var initializeContinuation: CheckedContinuation<Bool, Never>?
    private var currentConfig: ACPConnectionConfig?
    private var materializedSessions = Set<String>()
    private var resumingSessions = Set<String>()
    private var lastInitializationError: Error?

    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "ACPClientManager.NetworkMonitor")
    private let defaults: UserDefaults
    private let serviceFactory: ((ACPClientConfiguration, JSONEncoder) -> ACPService)?
    private let clientIdKey = "ACPClientManager.clientId"
    private let lastConnectedAtKey = "ACPClientManager.lastConnectedAt"

    // MARK: - Errors

    public struct NetworkOfflineError: LocalizedError, Sendable {
        public var errorDescription: String? { "The Internet connection appears to be offline." }
        public init() {}
    }

    // MARK: - Initialization

    public init(
        defaults: UserDefaults = .standard,
        clientId: String? = nil,
        shouldStartNetworkMonitoring: Bool = true,
        serviceFactory: ((ACPClientConfiguration, JSONEncoder) -> ACPService)? = nil
    ) {
        self.defaults = defaults
        self.serviceFactory = serviceFactory

        // Load or generate persistent client ID
        if let providedId = clientId {
            self.clientId = providedId
        } else if let storedId = defaults.string(forKey: clientIdKey), !storedId.isEmpty {
            self.clientId = storedId
        } else {
            let newId = UUID().uuidString
            defaults.set(newId, forKey: clientIdKey)
            self.clientId = newId
        }

        // Load last connected timestamp
        let timestamp = defaults.double(forKey: lastConnectedAtKey)
        if timestamp > 0 {
            lastConnectedAt = Date(timeIntervalSince1970: timestamp)
        }

        if shouldStartNetworkMonitoring {
            startNetworkMonitoring()
        }
    }

    deinit {
        networkMonitor.cancel()
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handleNetworkPathChange(path)
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    private func handleNetworkPathChange(_ path: NWPath) {
        let available = path.status == .satisfied
        guard available != isNetworkAvailable else { return }
        isNetworkAvailable = available

        delegate?.clientManager(self, didChangeNetworkAvailability: available)

        if available {
            log("Network reachable, resuming connection")
            reconnectTask?.cancel()
            reconnectTask = nil
            if shouldAutoReconnect {
                resumeConnectionIfNeeded()
            }
        } else {
            log("Network appears to be offline")
            reconnectTask?.cancel()
            reconnectTask = nil
            isConnecting = false
            reconnectAttempts = 0
            Task { @MainActor in
                await service?.disconnect()
                service = nil
            }
            if connectionState != .disconnected {
                connectionState = .failed(NetworkOfflineError())
                delegate?.clientManager(self, didChangeState: connectionState)
            }
        }
    }

    // MARK: - Connection

    /// Connects to the server with the given configuration.
    ///
    /// - Parameters:
    ///   - config: The connection configuration.
    ///   - resetReconnectAttempts: Whether to reset the reconnect counter.
    ///   - completion: Optional callback with success/failure result.
    public func connect(
        config: ACPConnectionConfig,
        resetReconnectAttempts: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        resetInitializationState()
        resetSessionTracking()
        currentConfig = config
        shouldAutoReconnect = true
        userInitiatedDisconnect = false

        if resetReconnectAttempts {
            reconnectAttempts = 0
        }
        reconnectTask?.cancel()
        reconnectTask = nil

        guard isNetworkAvailable else {
            log("Network offline; waiting to reconnect")
            connectionState = .failed(NetworkOfflineError())
            delegate?.clientManager(self, didChangeState: connectionState)
            isConnecting = false
            resolveContinuation(success: false, completion: completion)
            return
        }

        let clientConfig = ACPClientConfiguration(
            endpoint: config.endpoint,
            authTokenProvider: config.authToken.map { token in { token } },
            additionalHeaders: buildConnectionHeaders(config: config),
            pingInterval: config.pingInterval
        )

        let encoder = JSONEncoder()
        if config.requiresUnescapedSlashes {
            encoder.outputFormatting.insert(.withoutEscapingSlashes)
        }

        let service = serviceFactory?(clientConfig, encoder) ?? {
            let client = ACPClient(configuration: clientConfig, logger: PrintLogger(), encoder: encoder)
            return ACPService(client: client)
        }()
        service.delegate = self
        self.service = service

        isConnecting = true
        connectContinuation = nil

        Task { @MainActor in
            do {
                try await service.connect()
                delegate?.clientManager(self, didCreateService: service)
                resolveContinuation(success: true, completion: completion)
            } catch {
                log("Connect error: \(error)")
                delegate?.clientManager(self, didEncounterError: error)
                isConnecting = false
                connectionState = .failed(error)
                delegate?.clientManager(self, didChangeState: connectionState)
                resolveContinuation(success: false, completion: completion)
                scheduleReconnectAttempt()
            }
        }
    }

    /// Connects and waits for the result asynchronously.
    public func connectAndWait(config: ACPConnectionConfig) async -> Bool {
        await withCheckedContinuation { continuation in
            connectContinuation?.resume(returning: false)
            connectContinuation = continuation
            connect(config: config) { success in
                continuation.resume(returning: success)
                self.connectContinuation = nil
            }
        }
    }

    /// Disconnects from the server.
    public func disconnect() {
        shouldAutoReconnect = false
        userInitiatedDisconnect = true
        reconnectAttempts = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        resetInitializationState()
        resetSessionTracking()

        let serviceToDisconnect = service

        Task { @MainActor in
            await serviceToDisconnect?.disconnect()
            
            if self.service === serviceToDisconnect {
                self.service = nil
                self.connectionState = .disconnected
                delegate?.clientManager(self, didChangeState: connectionState)
                self.isConnecting = false
            }
        }
    }

    /// Resumes connection if previously connected and not user-disconnected.
    public func resumeConnectionIfNeeded() {
        guard !userInitiatedDisconnect else { return }
        guard isNetworkAvailable else { return }
        guard let config = currentConfig else { return }

        shouldAutoReconnect = true
        reconnectAttempts = 0

        guard !isConnecting else { return }

        if connectionState != .connected {
            connect(config: config, resetReconnectAttempts: true)
        }
    }

    // MARK: - Initialization

    /// Sends initialize if needed and waits for completion.
    public func initializeAndWait(payload: ACPInitializationPayload) async -> Bool {
        if isInitialized { return true }
        guard let service else {
            log("Not connected")
            return false
        }
        guard connectionState == .connected else {
            log("Not connected")
            return false
        }

        return await withCheckedContinuation { continuation in
            initializeContinuation?.resume(returning: false)
            initializeContinuation = continuation
            if isInitializing {
                return
            }

            isInitializing = true
            lastInitializationError = nil

            Task { @MainActor in
                defer { isInitializing = false }
                do {
                    let response = try await service.initialize(payload)
                    let success = response.resultValue != nil
                    isInitialized = success
                    if !success {
                        log("Initialize failed: empty result")
                    }
                    resolveInitialization(success: success)
                } catch {
                    if case ACPServiceError.rpc(_, let rpcError) = error,
                       rpcError.message.lowercased().contains("already initialized") {
                        isInitialized = true
                        lastInitializationError = nil
                        log("Initialize skipped: already initialized")
                        resolveInitialization(success: true)
                        return
                    }
                    isInitialized = false
                    lastInitializationError = error
                    log("Initialize error: \(error)")
                    resolveInitialization(success: false)
                }
            }
        }
    }

    private func autoInitializeIfNeeded() {
        guard shouldAutoInitialize else { return }
        guard !isInitialized, !isInitializing else { return }
        guard let payload = initializationPayloadProvider?() else {
            log("Auto-initialize skipped: missing payload provider")
            return
        }

        Task { @MainActor in
            _ = await initializeAndWait(payload: payload)
        }
    }

    // MARK: - Health Check

    /// Verifies the WebSocket connection is alive; reconnects if not.
    public func verifyConnectionHealth() async {
        guard shouldAutoReconnect else { return }
        guard isNetworkAvailable else { return }
        guard !isConnecting else { return }
        guard let config = currentConfig else { return }

        guard let service else {
            connectionState = .disconnected
            delegate?.clientManager(self, didChangeState: connectionState)
            connect(config: config, resetReconnectAttempts: false)
            return
        }

        do {
            try await withTimeout(seconds: healthCheckTimeout) {
                try await service.ping()
            }
        } catch {
            log("Health check failed: \(error.localizedDescription)")
            reconnectTask?.cancel()
            reconnectTask = nil
            await service.disconnect()
            self.service = nil
            connectionState = .disconnected
            delegate?.clientManager(self, didChangeState: connectionState)
            isConnecting = false
            connect(config: config, resetReconnectAttempts: false)
        }
    }

    // MARK: - Reconnection

    private func scheduleReconnectAttempt() {
        guard shouldAutoReconnect else { return }
        guard isNetworkAvailable else {
            reconnectTask?.cancel()
            reconnectTask = nil
            return
        }
        guard reconnectAttempts < maxReconnectAttempts else {
            shouldAutoReconnect = false
            log("Reached maximum reconnect attempts (\(maxReconnectAttempts)); stopping auto-retry")
            return
        }
        guard !isConnecting, connectionState != .connected else { return }
        guard let config = currentConfig else { return }

        reconnectTask?.cancel()
        reconnectAttempts += 1

        let delay = reconnectBaseDelay * pow(2.0, Double(reconnectAttempts - 1))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                guard self.shouldAutoReconnect,
                      self.connectionState != .connected,
                      !self.isConnecting else { return }
                self.connect(config: config, resetReconnectAttempts: false)
            }
        }
    }

    // MARK: - Headers

    private func buildConnectionHeaders(config: ACPConnectionConfig) -> [String: String] {
        var headers: [String: String] = [:]

        // Cloudflare Access headers
        if let cfId = config.cloudflareAccessClientId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cfId.isEmpty {
            headers["CF-Access-Client-Id"] = cfId
        }
        if let cfSecret = config.cloudflareAccessClientSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cfSecret.isEmpty {
            headers["CF-Access-Client-Secret"] = cfSecret
        }

        // Persistent client ID for session resumption
        headers["X-Client-Id"] = clientId

        return headers
    }

    // MARK: - Helpers

    private func resolveContinuation(success: Bool, completion: ((Bool) -> Void)?) {
        if let continuation = connectContinuation {
            continuation.resume(returning: success)
            connectContinuation = nil
        } else {
            completion?(success)
        }
    }

    private func resolveInitialization(success: Bool) {
        if let continuation = initializeContinuation {
            continuation.resume(returning: success)
            initializeContinuation = nil
        }
    }

    private func resetInitializationState() {
        isInitialized = false
        isInitializing = false
        lastInitializationError = nil
        resolveInitialization(success: false)
    }

    private func resetSessionTracking() {
        materializedSessions.removeAll()
        resumingSessions.removeAll()
    }

    private func log(_ message: String) {
        delegate?.clientManager(self, didLog: message)
    }

    // MARK: - Session Tracking

    public func isSessionMaterialized(_ sessionId: String) -> Bool {
        materializedSessions.contains(sessionId)
    }

    public func markSessionMaterialized(_ sessionId: String) {
        materializedSessions.insert(sessionId)
    }

    public func isResumingSession(_ sessionId: String) -> Bool {
        resumingSessions.contains(sessionId)
    }

    public func setResumingSession(_ sessionId: String, isResuming: Bool) {
        if isResuming {
            resumingSessions.insert(sessionId)
        } else {
            resumingSessions.remove(sessionId)
        }
    }

    public func resetSessionState() {
        resetSessionTracking()
    }
}

// MARK: - ACPServiceDelegate

extension ACPClientManager: ACPServiceDelegate {
    public func acpService(_ service: ACPService, didReceiveNotification notification: ACP.AnyMessage) {
        guard service === self.service else { return }
        delegate?.clientManager(self, didReceiveNotification: notification)
    }

    public func acpService(_ service: ACPService, didReceiveMessage message: ACPWireMessage) {
        guard service === self.service else { return }
        delegate?.clientManager(self, didReceiveMessage: message)
    }

    public func acpService(_ service: ACPService, willSend request: ACP.AnyRequest) {
        guard service === self.service else { return }
        delegate?.clientManager(self, willSendRequest: request)
    }

    public func acpService(_ service: ACPService, didChangeState state: ACPConnectionState) {
        guard service === self.service else { return }

        connectionState = state
        isConnecting = (state == .connecting)

        delegate?.clientManager(self, didChangeState: state)

        switch state {
        case .connected:
            isConnecting = false
            reconnectAttempts = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            let now = Date()
            lastConnectedAt = now
            defaults.set(now.timeIntervalSince1970, forKey: lastConnectedAtKey)
            resolveContinuation(success: true, completion: nil)
            autoInitializeIfNeeded()

        case .failed:
            isConnecting = false
            resetInitializationState()
            resetSessionTracking()
            resolveContinuation(success: false, completion: nil)
            scheduleReconnectAttempt()

        case .disconnected:
            isConnecting = false
            resetInitializationState()
            resetSessionTracking()
            scheduleReconnectAttempt()

        case .connecting:
            break
        }
    }

    public func acpService(_ service: ACPService, didEncounterError error: Error) {
        guard service === self.service else { return }
        delegate?.clientManager(self, didEncounterError: error)
        if connectionState != .connected {
            scheduleReconnectAttempt()
        }
    }

    // MARK: - Testing Support

    /// Sets a service for testing purposes.
    /// This allows tests to inject a pre-configured service for verifying message sending.
    public func setServiceForTesting(_ testService: ACPService?) {
        service = testService
        if testService != nil {
            connectionState = .connected
        }
    }
}

// MARK: - Timeout Helper

private func withTimeout<T: Sendable>(seconds: Double, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}