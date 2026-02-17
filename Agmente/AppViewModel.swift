import SwiftUI
import Network
import Combine
import ACPClient
import ACP

/// Phase 3: AppViewModel - Application-level coordinator
/// Manages servers, global settings, and app-level state.
/// Each server has its own ServerViewModel (Phase 2), which manages sessions.
@MainActor
final class AppViewModel: ObservableObject, ACPClientManagerDelegate, ACPSessionCacheDelegate {
    // `ACP` also defines `SessionSummary`; keep local usages pinned to ACPClient.
    typealias SessionSummary = ACPClientSessionSummary

    private static let defaultScheme = "ws"

    // Connection / selection
    @Published var scheme: String = "ws" {
        didSet { persistActiveServerConfig() }
    }
    @Published var endpointHost: String = "" {
        didSet { persistActiveServerConfig() }
    }
    @Published var token: String = "" {
        didSet { persistActiveServerConfig() }
    }
    @Published var cfAccessClientId: String = "" {
        didSet { persistActiveServerConfig() }
    }
    @Published var cfAccessClientSecret: String = "" {
        didSet { persistActiveServerConfig() }
    }
    
    /// Connection state delegated to connectionManager.
    var connectionState: ACPConnectionState { connectionManager.connectionState }
    /// Whether a connection attempt is in progress.
    var isConnecting: Bool { connectionManager.isConnecting }
    /// Whether network is available.
    var isNetworkAvailable: Bool { connectionManager.isNetworkAvailable }
    /// Last successful connection timestamp.
    var lastConnectedAt: Date? { connectionManager.lastConnectedAt }
    /// Whether initialize has completed for the current connection.
    private var isInitializedOnConnection: Bool { connectionManager.isInitialized }
    
    @Published var devModeEnabled: Bool = false {
        didSet { defaults.set(devModeEnabled, forKey: devModeKey) }
    }
    @Published var codexSessionLoggingEnabled: Bool = false {
        didSet {
            defaults.set(codexSessionLoggingEnabled, forKey: codexSessionLoggingKey)
            if !codexSessionLoggingEnabled {
                Task { await codexSessionLogger.endSession() }
            } else {
                startCodexLoggingIfNeeded()
            }
        }
    }

    @Published private(set) var servers: [ACPServerConfiguration] = []
    @Published var selectedServerId: UUID? {
        didSet {
            // Update cached server properties when switching servers
            if let serverId = selectedServerId,
               let viewModel = serverViewModels[serverId] {
                updateCachedServerProperties(from: viewModel)
            } else {
                // Clear cached properties when no server is selected
                serverSessionSummaries = []
                serverSessionId = ""
                serverIsStreaming = false
                serverAgentInfo = nil
                serverIsPendingSession = false
            }
        }
    }

    // Phase 2: ServerViewModel instances (one per server)
    // Uses existential type to support both ACP and Codex server view models
    private var serverViewModels: [UUID: any ServerViewModelProtocol] = [:]
    
    /// Cancellables for observing child view model changes.
    private var serverViewModelCancellables: [UUID: AnyCancellable] = [:]

    /// Returns the ServerViewModel for the selected server.
    /// Returns concrete ServerViewModel for ACP servers, nil for Codex (use selectedCodexServerViewModel).
    var selectedServerViewModel: ServerViewModel? {
        guard let serverId = selectedServerId else { return nil }
        return serverViewModels[serverId] as? ServerViewModel
    }

    /// Returns the CodexServerViewModel for the selected server if it's a Codex server.
    var selectedCodexServerViewModel: CodexServerViewModel? {
        guard let serverId = selectedServerId else { return nil }
        return serverViewModels[serverId] as? CodexServerViewModel
    }

    /// Returns the server view model for the selected server, regardless of type.
    var selectedServerViewModelAny: (any ServerViewModelProtocol)? {
        guard let serverId = selectedServerId else { return nil }
        return serverViewModels[serverId]
    }

    // MARK: - Unified Server Properties (work for both ACP and Codex servers)
    // Use these in UI instead of selectedServerViewModel?.property
    // These are @Published cached values that update when child view models change,
    // avoiding blanket objectWillChange forwarding for better performance.

    /// Session summaries for the selected server (works for both ACP and Codex).
    @Published private(set) var serverSessionSummaries: [SessionSummary] = []

    /// Current session ID for the selected server (works for both ACP and Codex).
    @Published private(set) var serverSessionId: String = ""

    /// Whether the selected server is currently streaming (works for both ACP and Codex).
    @Published private(set) var serverIsStreaming: Bool = false

    /// Agent info for the selected server (works for both ACP and Codex).
    @Published private(set) var serverAgentInfo: AgentProfile? = nil

    /// Whether there's a pending session for the selected server (works for both ACP and Codex).
    @Published private(set) var serverIsPendingSession: Bool = false

    // Initialization
    @Published var clientName: String = "Agmente iOS"
    @Published var clientVersion: String = "0.1.0"
    /// iOS client cannot access remote filesystem - set to false by default
    @Published var supportsFSRead: Bool = false
    @Published var supportsFSWrite: Bool = false
    /// iOS client cannot provide terminal access - set to false by default
    @Published var supportsTerminal: Bool = false
    @Published private(set) var initializationSummary: String = "Not initialized"

    // Session
    @Published var workingDirectory: String = "/" {
        didSet {
            persistActiveServerConfig()
            guard let serverId = selectedServerId else { return }
            rememberUsedWorkingDirectory(workingDirectory, forServerId: serverId)
        }
    }

    // Phase 2: Session properties moved to ServerViewModel
    // Access via: selectedServerViewModel?.sessionId
    // Access via: selectedServerViewModel?.selectedSessionId
    // Access via: selectedServerViewModel?.sessionSummaries
    // Access via: selectedServerViewModel?.currentSessionViewModel
    // Access via: selectedServerViewModel?.isStreaming

    // Private computed properties for internal AppViewModel use only
    // UI should access these directly from ServerViewModel as @ObservedObject
    private var sessionId: String {
        get { selectedServerViewModelAny?.sessionId ?? "" }
        set { selectedServerViewModelAny?.sessionId = newValue }
    }
    private var sessionSummaries: [SessionSummary] {
        get { selectedServerViewModelAny?.sessionSummaries ?? [] }
        set { selectedServerViewModelAny?.sessionSummaries = newValue }
    }
    private var sessionViewModel: ACPSessionViewModel? { selectedServerViewModelAny?.currentSessionViewModel }

    // Session Modes
    @Published private(set) var availableModes: [AgentModeOption] = []

    // Chat state - owned by per-session viewmodels

    /// Simplifies tool call titles for preview display.
    private func simplifyToolTitle(_ title: String) -> String {
        var result = title
        
        // Remove common prefixes like "Edit: ", "Read: ", etc.
        let prefixes = ["Edit: ", "Read: ", "Write: ", "Create: ", "Delete: ", "Search: ", "Run: "]
        for prefix in prefixes {
            if result.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count))
                break
            }
        }
        
        // Truncate if too long
        if result.count > 45 {
            result = String(result.prefix(45)) + "…"
        }
        
        return result
    }

    // Prompt
    @Published var promptText: String = ""
    
    // Logs / updates
    @Published private(set) var updates: [LogLine] = []

    /// Connection manager handles network monitoring, reconnection, and connection lifecycle.
    private let connectionManager: ACPClientManager
    /// Convenience accessor for the active service.
    private var service: ACPService? { connectionManager.service }
    /// Detected protocol per server for the current app process (re-detected on reconnect if needed).
    private var connectedProtocols: [UUID: ACPConnectedProtocol] = [:]
    private let encoder = JSONEncoder()
    private var pendingRequests: [ACP.ID: String] = [:]
    private var codexAckNeeded: Set<UUID> = []
    private let codexSessionLogger = CodexSessionLogger(maxFiles: 3)
    private var pendingSessionLoad: (serverId: UUID, sessionId: String)?
    /// Capability flags are sourced from AgentProfile (protocol payloads) and updated on errors.
    /// Tracks pending permission requests by request ID -> (sessionId, toolCallId)
    /// Cached agent info per server, parsed from initialize response.
    private var agentInfoCache: [UUID: AgentProfile] = [:]
    /// Tracks ongoing multi-CWD session list fetches: serverId -> (remaining count, accumulated sessions)
    private var pendingMultiCwdFetch: [UUID: (remaining: Int, sessions: [SessionSummary])] = [:]
    /// Tracks the working directory for a pending session/new request, so we can associate it with the session when the response arrives.
    private var pendingNewSessionCwd: String?
    /// Tracks the placeholder session ID for an in-flight session/new, so we can migrate cached state immediately when the response arrives.
    private var pendingNewSessionPlaceholderId: String?
    /// Tracks sessions that were created locally and haven't been materialized on the server yet.
    private var pendingLocalSessions: Set<String> = []
    /// Optional per-session working directory overrides for locally created sessions.
    private var pendingLocalSessionCwds: [String: String] = [:]
    /// Tracks in-flight session/new tasks by placeholder session ID.
    /// Allows sendPrompt to await completion and avoids duplicate creation calls.
    private var creatingSessionTasks: [String: Task<Void, Never>] = [:]
    /// Maps placeholder session IDs to their resolved server-returned IDs.
    /// Populated by finalizePendingSessionCreation when session/new response is processed.
    private var resolvedSessionIds: [String: String] = [:]
    private var resumeRefreshTask: Task<Void, Never>?
    private var lastResumeRefreshAt: Date?
    private var pendingNetworkRefresh: Bool = false
    private let defaults: UserDefaults
    private let lastServerKey = "Agmente.lastServerId"
    private let devModeKey = "Agmente.devModeEnabled"
    private let codexSessionLoggingKey = "Agmente.codexSessionLoggingEnabled"
    private let serverLifecycleController: ServerLifecycleController

    private func debugLog(_ message: String) {
        guard devModeEnabled else { return }
        append("[debug] \(message)")
    }

    private func debugLogSessionStats(label: String, sessions: [SessionSummary]) {
        guard devModeEnabled else { return }
        let calendar = Calendar.current
        let now = Date()
        let dates = sessions.compactMap { $0.updatedAt }
        let nilCount = sessions.count - dates.count
        let todayCount = dates.filter { calendar.isDateInToday($0) }.count
        let yesterdayCount = dates.filter { calendar.isDateInYesterday($0) }.count
        let recent10m = dates.filter { abs($0.timeIntervalSince(now)) <= 10 * 60 }.count
        let minDate = dates.min()
        let maxDate = dates.max()

        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        debugLog(
            "\(label): total=\(sessions.count) updatedAtNil=\(nilCount) today=\(todayCount) yesterday=\(yesterdayCount) recent10m=\(recent10m) min=\(minDate.map { df.string(from: $0) } ?? "nil") max=\(maxDate.map { df.string(from: $0) } ?? "nil")"
        )

        let sample = sessions.prefix(5).map { summary in
            let title = summary.title ?? "nil"
            let date = summary.updatedAt.map { df.string(from: $0) } ?? "nil"
            return "{id:\(summary.id.prefix(8)) title:\(title.prefix(24)) updatedAt:\(date)}"
        }.joined(separator: ", ")
        if !sample.isEmpty {
            debugLog("\(label) sample: \(sample)")
        }
    }

    // In-memory caches keyed by server ID
    private var sessionCache: [UUID: String] = [:]
    private var chatCache: [UUID: [String: [ChatMessage]]] = [:] // serverId -> sessionId -> messages
    private var stopReasonCache: [UUID: [String: String]] = [:] // serverId -> sessionId -> stopReason
    private var updatesCache: [UUID: [LogLine]] = [:]
    private var sessionSummaryCache: [UUID: [SessionSummary]] = [:]
    private var initializationCache: [UUID: String] = [:]
    private var initializedServers: Set<UUID> = []

    /// Tracks whether this is the initial app launch. Used to auto-open last session only on startup,
    /// not on every server switch. Set to false after first initialization completes.
    @Published private(set) var isInitialAppLaunch: Bool = true

    private let storage: SessionStorage

    init(
        storage: SessionStorage = .shared,
        defaults: UserDefaults = .standard,
        connectionManager: ACPClientManager? = nil,
        shouldStartNetworkMonitoring: Bool = true,
        shouldConnectOnStartup: Bool = true
    ) {
        self.storage = storage
        self.defaults = defaults
        self.serverLifecycleController = ServerLifecycleController(storage: storage, defaults: defaults)
        self.serverLifecycleController.migrateLegacyConnectionDefaultsIfNeeded(connectionManagerProvided: connectionManager != nil)
        self.connectionManager = connectionManager ?? ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: shouldStartNetworkMonitoring
        )
        self.connectionManager.initializationPayloadProvider = { [weak self] in
            self?.makeInitializationPayload()
        }
        // Phase 1: Observation setup moved to per-session creation
        // (no longer setting up a single sessionViewModel observation here)

        servers = serverLifecycleController.loadServersFromStorage()
        restoreSelectionFromDefaults()
        devModeEnabled = defaults.bool(forKey: devModeKey)
        codexSessionLoggingEnabled = defaults.bool(forKey: codexSessionLoggingKey)

        // Phase 2: Create ServerViewModel instances for each server
        // Use the appropriate ViewModel type based on serverType
        for server in servers {
            let serverVM: any ServerViewModelProtocol
            switch server.serverType {
            case .acp:
                serverVM = createServerViewModel(for: server)
            case .codexAppServer:
                serverVM = createCodexServerViewModel(for: server)
                connectedProtocols[server.id] = .codexAppServer
            }
            serverViewModels[server.id] = serverVM
            observeServerViewModel(serverVM)
        }

        // Set ourselves as the delegate after initialization
        self.connectionManager.delegate = self
        // Phase 1: Delegates are now set per session view model in createSessionViewModel()

        if shouldConnectOnStartup {
            connectInitializeAndFetchSessions()
        }
    }

    // MARK: - Phase 2: ServerViewModel Management

    /// Creates a ServerViewModel instance for a server configuration.
    private func createServerViewModel(for config: ACPServerConfiguration) -> ServerViewModel {
        return ServerViewModel(
            id: config.id,
            name: config.name,
            scheme: config.scheme,
            host: config.host,
            token: config.token,
            cfAccessClientId: config.cfAccessClientId,
            cfAccessClientSecret: config.cfAccessClientSecret,
            workingDirectory: config.workingDirectory,
            connectionManager: connectionManager,  // TODO Phase 2: Refactor so each ServerViewModel owns its own ACPClientManager instance instead of sharing AppViewModel.connectionManager, to avoid cross-server connection state confusion
            getService: { [weak self] in self?.service },
            append: { [weak self] text in self?.append(text) },
            logWire: { [weak self] direction, message in self?.logWire(direction, message: message) },
            cacheDelegate: self,  // AppViewModel implements ACPSessionCacheDelegate
            // Note: ServerViewModel now implements ACPSessionEventDelegate itself
            storage: storage       // Pass storage for session persistence
        )
    }

    /// Updates or creates a ServerViewModel when server config changes.
    private func updateServerViewModel(for config: ACPServerConfiguration) {
        if let existing = serverViewModels[config.id] {
            // Update existing
            existing.name = config.name
            existing.scheme = config.scheme
            existing.host = config.host
            existing.token = config.token
            existing.cfAccessClientId = config.cfAccessClientId
            existing.cfAccessClientSecret = config.cfAccessClientSecret
            existing.workingDirectory = config.workingDirectory
        } else {
            // Create new
            let newVM = createServerViewModel(for: config)
            serverViewModels[config.id] = newVM
            observeServerViewModel(newVM)
        }
    }

    /// Removes a ServerViewModel.
    private func removeServerViewModel(for serverId: UUID) {
        serverViewModels[serverId]?.removeAllSessionViewModels()
        serverViewModels.removeValue(forKey: serverId)
        serverViewModelCancellables.removeValue(forKey: serverId)
    }
    
    /// Sets up observation of a server view model to update cached server properties.
    /// Instead of forwarding all objectWillChange events, we selectively observe specific
    /// published properties to minimize UI redraw fanout.
    private func observeServerViewModel(_ viewModel: any ServerViewModelProtocol) {
        let serverId = viewModel.id

        // Observe specific properties from child view model to update our cached @Published values.
        // This approach ensures UI only redraws when relevant state changes, rather than on every
        // child update (including high-frequency streaming deltas).
        if let serverVM = viewModel as? ServerViewModel {
            let cancellable = serverVM.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self = self,
                          self.selectedServerId == serverId else { return }
                    self.updateCachedServerProperties(from: serverVM)
                }
            serverViewModelCancellables[serverId] = cancellable
        } else if let codexVM = viewModel as? CodexServerViewModel {
            let cancellable = codexVM.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self = self,
                          self.selectedServerId == serverId else { return }
                    self.updateCachedServerProperties(from: codexVM)
                }
            serverViewModelCancellables[serverId] = cancellable
        }

        // Update cached values immediately for the currently selected server
        if selectedServerId == serverId {
            updateCachedServerProperties(from: viewModel)
        }
    }

    /// Updates cached server properties from the given view model.
    /// Only publishes changes for properties that actually changed, reducing unnecessary redraws.
    private func updateCachedServerProperties(from viewModel: any ServerViewModelProtocol) {
        // Update session summaries if changed
        let newSummaries = viewModel.sessionSummaries
        if serverSessionSummaries != newSummaries {
            serverSessionSummaries = newSummaries
        }

        // Update session ID if changed
        let newSessionId = viewModel.sessionId
        if serverSessionId != newSessionId {
            serverSessionId = newSessionId
        }

        // Update streaming state if changed
        let newIsStreaming = viewModel.isStreaming
        if serverIsStreaming != newIsStreaming {
            serverIsStreaming = newIsStreaming
        }

        // Update agent info if changed
        let newAgentInfo = viewModel.agentInfo
        // AgentProfile doesn't conform to Equatable, so we compare by reference/presence
        if (serverAgentInfo == nil) != (newAgentInfo == nil) ||
           (serverAgentInfo?.displayName != newAgentInfo?.displayName) ||
           (serverAgentInfo?.version != newAgentInfo?.version) {
            serverAgentInfo = newAgentInfo
        }

        // Update pending session state if changed
        let newIsPendingSession = viewModel.isPendingSession
        if serverIsPendingSession != newIsPendingSession {
            serverIsPendingSession = newIsPendingSession
        }
    }

    /// Creates a CodexServerViewModel for a server configuration.
    private func createCodexServerViewModel(for config: ACPServerConfiguration) -> CodexServerViewModel {
        let viewModel = CodexServerViewModel(
            id: config.id,
            name: config.name,
            scheme: config.scheme,
            host: config.host,
            token: config.token,
            cfAccessClientId: config.cfAccessClientId,
            cfAccessClientSecret: config.cfAccessClientSecret,
            workingDirectory: config.workingDirectory,
            connectionManager: connectionManager,
            getService: { [weak self] in self?.service },
            append: { [weak self] text in self?.append(text) },
            logWire: { [weak self] direction, message in self?.logWire(direction, message: message) },
            sessionLogger: codexSessionLogger,
            isSessionLoggingEnabled: { [weak self] in self?.codexSessionLoggingEnabled ?? false },
            cacheDelegate: self,
            storage: storage
        )
        if codexAckNeeded.contains(config.id) {
            viewModel.markInitializedAckNeeded()
            codexAckNeeded.remove(config.id)
        }
        return viewModel
    }

    /// Switches a server from ServerViewModel to CodexServerViewModel.
    /// Called when Codex app-server protocol is detected after initialize.
    private func switchToCodexServerViewModel(for serverId: UUID) {
        guard let config = servers.first(where: { $0.id == serverId }) else {
            append("Warning: Cannot switch to CodexServerViewModel - server config not found")
            return
        }

        // Clean up old ACP view model before switching.
        let oldViewModel = serverViewModels[serverId]
        oldViewModel?.removeAllSessionViewModels()
        serverViewModelCancellables.removeValue(forKey: serverId)

        // Create new CodexServerViewModel
        let codexViewModel = createCodexServerViewModel(for: config)

        serverViewModels[serverId] = codexViewModel
        observeServerViewModel(codexViewModel)
        append("Switched to CodexServerViewModel for \(config.name)")
    }

    // MARK: - Phase 1: Per-Session ViewModel Management

    /// Creates a new SessionViewModel instance for the given session ID.
    private func createSessionViewModel(for sessionId: String) -> ACPSessionViewModel {
        let viewModel = ACPSessionViewModel(
            dependencies: .init(
                getService: { [weak self] in self?.service },
                append: { [weak self] text in self?.append(text) },
                logWire: { [weak self] direction, message in
                    self?.logWire(direction, message: message)
                }
            )
        )

        // Set delegates
        viewModel.cacheDelegate = self

        return viewModel
    }

    // Phase 2: Session view model management is now delegated to ServerViewModel
    // These methods are kept for compatibility and delegate to the selected server

    /// Migrates a session view model from placeholder ID to resolved ID.
    /// Delegates to selected ServerViewModel.
    private func migrateSessionViewModel(from placeholderId: String, to resolvedId: String) {
        selectedServerViewModelAny?.migrateSessionViewModel(from: placeholderId, to: resolvedId)
    }

    /// Removes a session view model and cleans up its observation.
    /// Delegates to selected ServerViewModel.
    private func removeSessionViewModel(for sessionId: String) {
        selectedServerViewModelAny?.removeSessionViewModel(for: sessionId)
    }

    /// Removes all session view models for a server.
    /// Delegates to the ServerViewModel for that server.
    private func removeAllSessionViewModels(for serverId: UUID) {
        serverViewModels[serverId]?.removeAllSessionViewModels()
    }

    private func connectInitializeAndFetchSessions() {
        serverLifecycleController.connectInitializeAndFetchSessions(
            selectedServerIdProvider: { [weak self] in self?.selectedServerId },
            isInitializedOnConnection: { [weak self] in self?.isInitializedOnConnection ?? false },
            connectAndWait: { [weak self] in await self?.connectAndWait() ?? false },
            initializeAndWait: { [weak self] in await self?.initializeAndWait() ?? false },
            fetchSessionList: { [weak self] in self?.fetchSessionList() }
        )
    }

    // MARK: Server management

    var currentServerName: String {
        selectedServer?.name ?? "Select server"
    }
    
    /// Returns the cached AgentProfile for the currently selected server, if available.
    var currentAgentInfo: AgentProfile? {
        guard let id = selectedServerId else { return nil }
        return agentInfoCache[id]
    }

    /// Best-effort support signals for critical session methods.
    /// `nil` means unknown for the selected server.
    var currentSessionListSupport: Bool? {
        guard let id = selectedServerId else { return nil }
        return sessionListSupportFlag(for: id)
    }

    var currentLoadSessionSupport: Bool? {
        guard let id = selectedServerId else { return nil }
        return agentInfoCache[id]?.capabilities.loadSession
    }
    
    /// Returns the default working directory for the selected server.
    var defaultWorkingDirectory: String {
        selectedServer?.workingDirectory ?? "/"
    }
    
    /// Returns the working directory for the currently active session.
    /// Falls back to the server's default if the session doesn't have a CWD.
    var currentSessionCwd: String {
        guard selectedServerId != nil, !sessionId.isEmpty else {
            return defaultWorkingDirectory
        }
        // Look up the session's CWD from session summaries
        if let summary = sessionSummaries.first(where: { $0.id == sessionId }),
           let cwd = summary.cwd {
            return cwd
        }
        return defaultWorkingDirectory
    }

    /// Returns all working directories we've observed/used for the selected server.
    /// Used to power the working directory picker and multi-CWD session listing.
    var usedWorkingDirectoryHistory: [String] {
        guard let serverId = selectedServerId else { return [] }
        var directories = storage.fetchUsedWorkingDirectories(forServerId: serverId)

        // Ensure current values are present so the picker always includes them.
        let candidates = [currentSessionCwd, workingDirectory]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !directories.contains(trimmed) {
                directories.insert(trimmed, at: 0)
            }
        }

        return directories
    }

    private func refreshImageAttachmentSupport(for serverId: UUID? = nil) {
        let resolvedId = serverId ?? selectedServerId
        let supportsImages = resolvedId.flatMap { agentInfoCache[$0]?.capabilities.promptCapabilities.image } ?? false
        sessionViewModel?.setSupportsImageAttachment(supportsImages)
    }

    /// True when the active session hasn't been materialized on the server yet.
    var isPendingSession: Bool {
        selectedServerViewModelAny?.isPendingSession ?? false
    }

    var selectedServer: ACPServerConfiguration? {
        guard let id = selectedServerId else { return nil }
        return servers.first(where: { $0.id == id })
    }

    enum AddServerValidationError: LocalizedError {
        case networkError(String)
        case localNetworkPermissionNeeded(String)
        case other(String)

        var errorDescription: String? {
            switch self {
            case .networkError(let message),
                 .localNetworkPermissionNeeded(let message),
                 .other(let message):
                return message
            }
        }

        var isLocalNetworkPermissionError: Bool {
            if case .localNetworkPermissionNeeded = self {
                return true
            }
            return false
        }
    }

    func validateServerConfiguration(
        name: String,
        scheme: String,
        host: String,
        token: String,
        cfAccessClientId: String,
        cfAccessClientSecret: String,
        workingDirectory: String,
        serverType: ServerType
    ) async -> Result<ValidatedServerConfiguration, Error> {
        let normalized = normalizeEndpointInput(scheme: scheme, host: host)
        let label = name.isEmpty ? "\(normalized.scheme)://\(normalized.host)" : name
        let urlString = "\(normalized.scheme)://\(normalized.host)"
        guard let url = URL(string: urlString) else {
            return .failure(AddServerValidationError.other("Invalid endpoint: \(urlString)"))
        }

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = ACPClientConfiguration(
            endpoint: url,
            authTokenProvider: trimmedToken.isEmpty ? nil : { trimmedToken },
            additionalHeaders: connectionHeaders(cfClientId: cfAccessClientId, cfClientSecret: cfAccessClientSecret),
            pingInterval: 15
        )
        let client = ACPClient(configuration: config, logger: PrintLogger())
        let service = ACPService(client: client)

        let clientCapabilities: [String: ACP.Value] = [
            "fs": .object([
                "readTextFile": .bool(supportsFSRead),
                "writeTextFile": .bool(supportsFSWrite)
            ]),
            "terminal": .bool(supportsTerminal),
        ]
        let initPayload = ACPInitializationPayload(
            protocolVersion: 1,
            clientName: clientName,
            clientVersion: clientVersion,
            clientCapabilities: clientCapabilities,
            capabilities: ["experimentalApi": .bool(true)]
        )

        var agentInfo: AgentProfile?
        func probeMethodSupport(service: ACPService, method: String, params: ACP.Value?) async -> Bool? {
            do {
                _ = try await service.call(method: method, params: params)
                return true
            } catch let error as ACPServiceError {
                switch error {
                case .rpc(_, let rpcError):
                    return rpcError.code == -32601 ? false : true
                default:
                    return nil
                }
            } catch {
                return nil
            }
        }

        do {
            try await service.connect()
            defer { Task { await service.disconnect() } }
            let response = try await service.initialize(initPayload)
            // Detect ACP vs Codex app-server from the initialize response.
            if let parsed = ACPInitializeParser.parse(result: response.resultValue) {
                switch parsed.connectedProtocol {
                case .codexAppServer:
                    if let userAgent = parsed.userAgent, let info = parsed.agentInfo {
                        // Codex app-server: acknowledge with `initialized` notification.
                        let initialized = ACPMessageBuilder.initializedNotification()
                        try? await service.sendMessage(initialized)
                        agentInfo = info
                    }
                case .acp, .none:
                    // ACP: parse AgentProfile and optionally probe method support.
                    if var parsedInfo = parsed.agentInfo {
                        applyEncodingRequirements(for: parsedInfo, service: service, log: false)
                        // Some agents misreport capability flags; probe for method existence to keep
                        // the Add Server summary card and runtime behavior aligned.
                        if let listSupport = await probeMethodSupport(service: service, method: "session/list", params: .object([:])) {
                            parsedInfo.capabilities.listSessions = listSupport
                        }
                        if let loadSupport = await probeMethodSupport(
                            service: service,
                            method: "session/load",
                            params: .object(["sessionId": .string("capability-probe")])
                        ) {
                            parsedInfo.capabilities.loadSession = loadSupport
                        }
                        agentInfo = parsedInfo
                    }
                }
            }
        } catch {
            let nsError = error as NSError
            let isLocalNetworkPermissionError = nsError.domain == NSURLErrorDomain
                && (-1200 ... -1001).contains(nsError.code)
                && isLocalNetworkHost(normalized.host)

            // Check if this is a local network connection error
            if isLocalNetworkPermissionError {
                // This is likely a local network permission issue
                // Return a special error type that the UI can handle gracefully
                // to avoid showing an error alert that interferes with the OS permission prompt
                return .failure(AddServerValidationError.localNetworkPermissionNeeded(
                    "Local network access is required. Please grant access when prompted by iOS and try again."
                ))
            }

            return .failure(AddServerValidationError.networkError("Unable to reach \(label): \(error.localizedDescription)"))
        }

        let validated = ValidatedServerConfiguration(
            name: name,
            scheme: normalized.scheme,
            host: normalized.host,
            token: token,
            cfAccessClientId: cfAccessClientId,
            cfAccessClientSecret: cfAccessClientSecret,
            workingDirectory: workingDirectory,
            serverType: serverType,
            agentInfo: agentInfo
        )

        return .success(validated)
    }

    func addValidatedServer(_ config: ValidatedServerConfiguration) {
        addServer(
            name: config.name,
            scheme: config.scheme,
            host: config.host,
            token: config.token,
            cfAccessClientId: config.cfAccessClientId,
            cfAccessClientSecret: config.cfAccessClientSecret,
            workingDirectory: config.workingDirectory,
            serverType: config.serverType,
            agentInfo: config.agentInfo
        )
    }

    func updateServer(_ id: UUID, with config: ValidatedServerConfiguration) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }

        let updated = ACPServerConfiguration(
            id: id,
            name: config.name,
            scheme: config.scheme,
            host: config.host,
            token: config.token,
            cfAccessClientId: config.cfAccessClientId,
            cfAccessClientSecret: config.cfAccessClientSecret,
            workingDirectory: sanitizeWorkingDirectory(config.workingDirectory)
        )

        let connectionChanged = servers[index].scheme != updated.scheme ||
                                servers[index].host != updated.host ||
                                servers[index].token != updated.token ||
                                servers[index].cfAccessClientId != updated.cfAccessClientId ||
                                servers[index].cfAccessClientSecret != updated.cfAccessClientSecret

        servers[index] = updated
        serverLifecycleController.persistServer(updated)
        updateServerViewModel(for: updated)

        // Cache new agentInfo if provided
        if let agentInfo = config.agentInfo {
            agentInfoCache[id] = agentInfo
            serverViewModels[id]?.updateAgentInfo(agentInfo)
        }

        // Reconnect if connection details changed and this is the active server
        if selectedServerId == id && connectionChanged {
            Task {
                connectionManager.disconnect()
                await connectInitializeAndFetchSessions()
            }
        }
    }

    func addServer(
        name: String,
        scheme: String,
        host: String,
        token: String,
        cfAccessClientId: String,
        cfAccessClientSecret: String,
        workingDirectory: String,
        serverType: ServerType = .acp,
        agentInfo: AgentProfile? = nil
    ) {
        let normalized = normalizeEndpointInput(scheme: scheme, host: host)
        let label = name.isEmpty ? "\(normalized.scheme)://\(normalized.host)" : name
        let server = ACPServerConfiguration(
            id: UUID(),
            name: label,
            scheme: normalized.scheme,
            host: normalized.host,
            token: token,
            cfAccessClientId: cfAccessClientId,
            cfAccessClientSecret: cfAccessClientSecret,
            workingDirectory: sanitizeWorkingDirectory(workingDirectory),
            serverType: serverType
        )
        servers.append(server)
        serverLifecycleController.persistServer(server)

        // Create the appropriate ViewModel based on serverType
        let serverVM: any ServerViewModelProtocol
        switch serverType {
        case .acp:
            serverVM = createServerViewModel(for: server)
        case .codexAppServer:
            serverVM = createCodexServerViewModel(for: server)
            // Set connected protocol for Codex since we know the type upfront
            connectedProtocols[server.id] = .codexAppServer
        }
        serverViewModels[server.id] = serverVM
        observeServerViewModel(serverVM)

        // Cache the AgentProfile if provided (from validation connection)
        if let agentInfo = agentInfo {
            agentInfoCache[server.id] = agentInfo
            serverVM.updateAgentInfo(agentInfo)
            // Mark as initialized since we already got the capabilities
            initializedServers.insert(server.id)
        }

        selectServer(server.id)
    }

    func selectServer(_ id: UUID) {
        let previousServerId = selectedServerId
        // Phase 2: Session state now lives in ServerViewModel - no need to clear here
        // Each ServerViewModel maintains its own state
        pendingSessionLoad = nil
        availableModes = []
        resolvedSessionIds.removeAll()
        
        persistCurrentServerState()
        let needsReconnect = service != nil

        selectedServerId = id
        defaults.set(id.uuidString, forKey: lastServerKey)
        pendingSessionLoad = nil
        connectionManager.resetSessionState()
        connectionManager.shouldAutoInitialize = initializedServers.contains(id)

        guard let server = servers.first(where: { $0.id == id }) else { return }
        scheme = server.scheme
        endpointHost = server.host
        token = server.token
        cfAccessClientId = server.cfAccessClientId
        cfAccessClientSecret = server.cfAccessClientSecret
        workingDirectory = server.workingDirectory

        applyCachedState(for: id)
        refreshImageAttachmentSupport(for: id)

        if needsReconnect {
            if let previousServerId {
                serverLifecycleController.enqueuePendingDisconnect(previousServerId)
            }
            connectionManager.disconnect()
            sessionViewModel?.resetStreamingState()
            connectInitializeAndFetchSessions()
        }
    }

    func loadCachedSessions() {
        // Phase 2: Delegate to ServerViewModel
        selectedServerViewModelAny?.loadCachedSessions()
    }

    func ensureSessionForActiveServer() {
        guard let serverId = selectedServerId else { return }
        let sessionToResume = pendingSessionLoad?.sessionId
        ?? sessionCache[serverId]

        guard let sessionToResume, !sessionToResume.isEmpty else {
            pendingSessionLoad = nil
            return
        }

        setActiveSession(sessionToResume)
        guard connectionState == .connected else { return }
        if canLoadSession(for: serverId),
           (selectedServerViewModelAny?.lastLoadedSession != sessionToResume || sessionViewModel?.chatMessages.isEmpty ?? true) {
            sendLoadSession(sessionToResume)
        } else {
            pendingSessionLoad = nil
        }
    }

    /// Delete a server and all its sessions.
    func deleteServer(_ id: UUID) {
        storage.deleteServer(id: id)
        servers.removeAll { $0.id == id }
        if defaults.string(forKey: lastServerKey) == id.uuidString {
            defaults.removeObject(forKey: lastServerKey)
        }
        
        // Clear caches
        sessionCache.removeValue(forKey: id)
        clearCache(for: id)
        updatesCache.removeValue(forKey: id)
        sessionSummaryCache.removeValue(forKey: id)
        initializationCache.removeValue(forKey: id)
        initializedServers.remove(id)
        agentInfoCache.removeValue(forKey: id)
        pendingMultiCwdFetch.removeValue(forKey: id)
        sessionViewModel?.removeServerCommandsCache(for: id)
        connectedProtocols.removeValue(forKey: id)

        // Phase 2: Remove ServerViewModel
        removeServerViewModel(for: id)

        if selectedServerId == id {
            // Clear the deleted server's endpoint from memory BEFORE selecting a new server.
            // This prevents persistCurrentServerState() from overwriting the new server's
            // config with the deleted server's endpoint values.
            scheme = "ws"
            endpointHost = ""
            token = ""
            cfAccessClientId = ""
            cfAccessClientSecret = ""
            workingDirectory = "/"
            
            if let newId = servers.first?.id {
                selectServer(newId)
            } else {
                // No servers left - clear remaining state
                selectedServerId = nil
                // Phase 2: Session state lives in ServerViewModel now
                updates = []
                refreshImageAttachmentSupport(for: nil)
            }
        }
    }

    /// Delete a session from memory and storage.
    func deleteSession(_ sessionId: String) {
        // Phase 2: Delegate to ServerViewModel
        guard let serverViewModel = selectedServerViewModel else { return }
        serverViewModel.deleteSession(sessionId)
    }

    /// Archive a session on the server (Codex app-server only).
    func archiveSession(_ sessionId: String) {
        guard let codexViewModel = selectedCodexServerViewModel else { return }
        codexViewModel.archiveSession(sessionId)
    }

    private func persistActiveServerConfig() {
        guard let serverId = selectedServerId,
              let index = servers.firstIndex(where: { $0.id == serverId }) else { return }
        let normalized = normalizeEndpointInput(scheme: scheme, host: endpointHost)

        let hostChanged = endpointHost != normalized.host
        let schemeChanged = scheme != normalized.scheme

        if hostChanged {
            endpointHost = normalized.host
        }

        if schemeChanged {
            scheme = normalized.scheme
        }

        if hostChanged || schemeChanged {
            return
        }

        servers[index].scheme = normalized.scheme
        servers[index].host = normalized.host
        servers[index].token = token
        servers[index].cfAccessClientId = cfAccessClientId
        servers[index].cfAccessClientSecret = cfAccessClientSecret
        servers[index].workingDirectory = workingDirectory

        // Persist to Core Data
        serverLifecycleController.persistServer(servers[index])
    }

    private func persistCurrentServerState() {
        persistActiveServerConfig()
        guard let serverId = selectedServerId else { return }
        sessionCache[serverId] = sessionId
        sessionViewModel?.saveChatState()
        updatesCache[serverId] = updates
        sessionSummaryCache[serverId] = sessionSummaries
        initializationCache[serverId] = initializationSummary
    }

    private func applyCachedState(for serverId: UUID) {
        // Only restore session list and updates - NOT the active session.
        // User must manually select a session from the list.
        updates = updatesCache[serverId] ?? []
        if let cachedSummaries = sessionSummaryCache[serverId], !cachedSummaries.isEmpty {
            setCachedSessionSummaries(cachedSummaries, for: serverId)
            debugLogSessionStats(label: "applyCachedState (from memory cache)", sessions: sessionSummaries)
        } else {
            // Try to load from Core Data (for servers without session/list)
            let storedSessions = storage.fetchSessions(forServerId: serverId)
            if !storedSessions.isEmpty {
                let summaries = storedSessions.map { $0.toSessionSummary() }
                debugLogSessionStats(label: "CoreData.fetchSessions (applyCachedState)", sessions: summaries)
                setCachedSessionSummaries(summaries, for: serverId)
                debugLogSessionStats(label: "After setCachedSessionSummaries (applyCachedState)", sessions: sessionSummaries)
            } else {
                setCachedSessionSummaries([], for: serverId)
            }
        }
        initializationSummary = initializationCache[serverId] ?? "Not initialized"
    }

    private func restoreSelectionFromDefaults() {
        guard let firstServer = servers.first else { return }
        if let savedId = defaults.string(forKey: lastServerKey),
           let uuid = UUID(uuidString: savedId),
           servers.contains(where: { $0.id == uuid }) {
            selectServer(uuid)
        } else {
            selectServer(firstServer.id)
        }
    }

    private func sessionListSupportFlag(for serverId: UUID) -> Bool? {
        agentInfoCache[serverId]?.capabilities.listSessions
    }

    private func applyEncodingRequirements(for agentInfo: AgentProfile, service: ACPService?, log: Bool) {
        guard agentInfo.requiresUnescapedSlashesInJSONRPC else { return }
        service?.setWithoutEscapingSlashesEnabled(true)
        if log {
            append("Enabled Codex JSON encoding workaround (no escaped slashes)")
        }
    }

    private func canLoadSession(for serverId: UUID) -> Bool {
        // Default to true - try server load first (will fail gracefully if not supported)
        // We can't default to false because agentInfo might not be set yet on startup
        agentInfoCache[serverId]?.capabilities.loadSession ?? true
    }

    private func canResumeSession(for serverId: UUID) -> Bool {
        agentInfoCache[serverId]?.capabilities.resumeSession ?? false
    }

    private func canFetchSessionList(for serverId: UUID, force: Bool = false) -> Bool {
        // Default to true - try server first, fall back to cache if it fails
        sessionListSupportFlag(for: serverId) ?? true
    }

    /// Whether the client owns the session list (e.g. agent lacks `session/list`).
    /// When true, it is safe to offer local-only destructive actions like "Delete Session".
    var canDeleteSessionsLocally: Bool {
        guard let serverId = selectedServerId else { return false }
        return sessionListSupportFlag(for: serverId) == false
    }

    /// Whether the selected server supports archiving sessions (Codex app-server only).
    var canArchiveSessions: Bool {
        selectedCodexServerViewModel != nil
    }

    private func sortSessionSummaries(_ summaries: [SessionSummary]) -> [SessionSummary] {
        var bestById: [String: SessionSummary] = [:]
        bestById.reserveCapacity(summaries.count)

        for summary in summaries {
            if let existing = bestById[summary.id] {
                switch (existing.updatedAt, summary.updatedAt) {
                case let (existingDate?, newDate?):
                    if newDate > existingDate {
                        bestById[summary.id] = summary
                    }
                case (nil, _?):
                    bestById[summary.id] = summary
                default:
                    break
                }
            } else {
                bestById[summary.id] = summary
            }
        }

        return bestById.values.sorted { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (lhsDate?, rhsDate?):
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.id < rhs.id
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.id < rhs.id
            }
        }
    }

    private func setSessionSummaries(_ summaries: [SessionSummary], for serverId: UUID) {
        let sorted = sortSessionSummaries(summaries)
        // Phase 2: sessionSummaries removed - now lives in ServerViewModel
        sessionSummaryCache[serverId] = sorted

        // CRITICAL: Also update the ServerViewModel's sessionSummaries
        serverViewModels[serverId]?.sessionSummaries = sorted

        rememberUsedWorkingDirectories(from: sorted, forServerId: serverId)
    }

    private func normalizeCorruptedCachedTimestampsIfNeeded(_ summaries: [SessionSummary]) -> [SessionSummary] {
        // If a previous app version persisted many sessions with `updatedAt = Date()`
        // (e.g., when timestamps were unknown), the cached list will incorrectly
        // group everything into "Today". Detect that pattern and treat timestamps
        // as unknown until the server provides real values.
        let dates = summaries.compactMap { $0.updatedAt }
        guard dates.count >= 20 else { return summaries }

        let now = Date()
        let recentWindow: TimeInterval = 10 * 60
        let spreadWindow: TimeInterval = 60

        let recent = dates.filter { abs($0.timeIntervalSince(now)) <= recentWindow }
        let recentRatio = Double(recent.count) / Double(dates.count)
        if recentRatio >= 0.9, let minDate = recent.min(), let maxDate = recent.max(), maxDate.timeIntervalSince(minDate) <= spreadWindow {
            debugLog("normalizeCorruptedCachedTimestampsIfNeeded: clearing updatedAt (cluster near now), count=\(summaries.count)")
            return summaries.map { summary in
                SessionSummary(id: summary.id, title: summary.title, cwd: summary.cwd, updatedAt: nil)
            }
        }

        // Broader heuristic: if we have a large list and nearly everything is "today",
        // it's likely from older persistence behavior that set `updatedAt` when saving.
        if dates.count >= 50 {
            let calendar = Calendar.current
            let todayCount = dates.filter { calendar.isDateInToday($0) }.count
            if Double(todayCount) / Double(dates.count) >= 0.95 {
                debugLog("normalizeCorruptedCachedTimestampsIfNeeded: clearing updatedAt (mostly today), count=\(summaries.count)")
                return summaries.map { summary in
                    SessionSummary(id: summary.id, title: summary.title, cwd: summary.cwd, updatedAt: nil)
                }
            }
        }

        return summaries
    }

    private func setCachedSessionSummaries(_ summaries: [SessionSummary], for serverId: UUID) {
        setSessionSummaries(normalizeCorruptedCachedTimestampsIfNeeded(summaries), for: serverId)
    }

    private func normalizeEndpointInput(scheme: String, host: String) -> (scheme: String, host: String) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseScheme = scheme.isEmpty ? Self.defaultScheme : scheme

        func normalize(from components: URLComponents) -> (scheme: String, host: String)? {
            guard let parsedHost = components.host else { return nil }

            let portString = components.port.map { ":\($0)" } ?? ""
            let path = components.percentEncodedPath
            let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
            let fragment = components.percentEncodedFragment.map { "#\($0)" } ?? ""

            let normalizedScheme = components.scheme ?? baseScheme
            let normalizedHost = parsedHost + portString + path + query + fragment

            return (normalizedScheme.isEmpty ? Self.defaultScheme : normalizedScheme, normalizedHost)
        }

        if let components = URLComponents(string: trimmedHost),
           let normalized = normalize(from: components) {
            return normalized
        }

        // Accept host-only input like "example.com/message" by temporarily prefixing the scheme.
        if let components = URLComponents(string: "\(baseScheme)://\(trimmedHost)"),
           let normalized = normalize(from: components) {
            return (normalized.scheme, normalized.host)
        }

        return (baseScheme, trimmedHost)
    }

    /// Checks if a host is a local network address (localhost, 127.0.0.1, ::1, or .local domains)
    private func isLocalNetworkHost(_ host: String) -> Bool {
        let lowercasedHost = host.lowercased()

        // Check for localhost
        if lowercasedHost.hasPrefix("localhost") || lowercasedHost.contains("//localhost") {
            return true
        }

        // Check for IPv4 loopback (127.0.0.1)
        if lowercasedHost.contains("127.0.0.1") {
            return true
        }

        // Check for IPv6 loopback (::1)
        if lowercasedHost.contains("::1") {
            return true
        }

        // Check for .local domains (mDNS/Bonjour)
        if lowercasedHost.contains(".local") {
            return true
        }

        // Check for private IP ranges (192.168.x.x, 10.x.x.x, 172.16-31.x.x)
        let components = host.split(separator: ":").first.map(String.init) ?? host
        let ipComponents = components.split(separator: ".").map(String.init)

        if ipComponents.count == 4,
           let first = Int(ipComponents[0]),
           let second = Int(ipComponents[1]) {
            // 192.168.x.x
            if first == 192 && second == 168 {
                return true
            }
            // 10.x.x.x
            if first == 10 {
                return true
            }
            // 172.16.x.x - 172.31.x.x
            if first == 172 && (16...31).contains(second) {
                return true
            }
        }

        return false
    }

    private var resolvedWorkingDirectory: String {
        let sanitized = sanitizeWorkingDirectory(workingDirectory)
        guard let endpointURL = currentEndpointURL else { return sanitized }
        return effectiveWorkingDirectory(endpointURL: endpointURL, configuredWorkingDirectory: sanitized)
    }

    private var currentEndpointURL: URL? {
        let normalized = normalizeEndpointInput(scheme: scheme, host: endpointHost)
        return URL(string: "\(normalized.scheme)://\(normalized.host)")
    }

    private func effectiveWorkingDirectory(endpointURL: URL, configuredWorkingDirectory: String) -> String {
        configuredWorkingDirectory
    }

    private func effectiveWorkingDirectory(_ configuredWorkingDirectory: String) -> String {
        guard let endpointURL = currentEndpointURL else { return configuredWorkingDirectory }
        return effectiveWorkingDirectory(endpointURL: endpointURL, configuredWorkingDirectory: configuredWorkingDirectory)
    }

    private func redactedWorkingDirectoryForStorage(_ cwd: String?) -> String? {
        cwd
    }

    private func sanitizeWorkingDirectory(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/" : trimmed
    }

    private func rememberUsedWorkingDirectory(_ cwd: String, forServerId serverId: UUID) {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        storage.addUsedWorkingDirectory(trimmed, forServerId: serverId)
    }

    private func rememberUsedWorkingDirectories(from summaries: [SessionSummary], forServerId serverId: UUID) {
        // `SessionSummary` lists are newest-first; remember in reverse so the most recent
        // working directories end up at the front of the MRU list.
        for summary in summaries.reversed() {
            guard let cwd = summary.cwd else { continue }
            rememberUsedWorkingDirectory(cwd, forServerId: serverId)
        }
    }

    private func rememberSession(_ id: String, cwd: String? = nil) {
        guard let serverId = selectedServerId, !id.isEmpty else { return }
        sessionCache[serverId] = id
        let configuredCwd = cwd ?? resolvedWorkingDirectory
        let sessionCwd = effectiveWorkingDirectory(configuredCwd)
        let storedCwd = redactedWorkingDirectoryForStorage(sessionCwd)
        let now = Date()
        
        if !sessionSummaries.contains(where: { $0.id == id }) {
            // Insert at the beginning with current timestamp so newest sessions appear first
            sessionSummaries.insert(SessionSummary(id: id, title: nil, cwd: storedCwd, updatedAt: now), at: 0)
        }
        setSessionSummaries(sessionSummaries, for: serverId)
        
        // Never persist local-only draft sessions.
        guard !pendingLocalSessions.contains(id) else { return }

        // Always persist sessions to Core Data immediately.
        // We don't know yet if the server supports session/list, so we persist
        // optimistically. If the server does support session/list, the persisted
        // sessions act as a backup. If not, they're essential for recovery.
        let title = sessionSummaries.first(where: { $0.id == id })?.title
        let storedInfo = StoredSessionInfo(
            sessionId: id,
            title: title,
            cwd: storedCwd,
            updatedAt: now
        )
        storage.saveSession(storedInfo, forServerId: serverId)
    }

    private func bumpSessionTimestamp(sessionId: String, cwd: String? = nil, timestamp: Date = Date()) {
        guard let serverId = selectedServerId else { return }
        let configuredCwd = sessionSummaries.first(where: { $0.id == sessionId })?.cwd ?? cwd ?? resolvedWorkingDirectory
        let resolvedCwd = effectiveWorkingDirectory(configuredCwd)
        let storedCwd = redactedWorkingDirectoryForStorage(resolvedCwd)

        if let index = sessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            let existing = sessionSummaries[index]
            let updated = SessionSummary(id: existing.id, title: existing.title, cwd: existing.cwd ?? storedCwd, updatedAt: timestamp)
            sessionSummaries.remove(at: index)
            sessionSummaries.insert(updated, at: 0)
        } else {
            sessionSummaries.insert(SessionSummary(id: sessionId, title: nil, cwd: storedCwd, updatedAt: timestamp), at: 0)
        }

        setSessionSummaries(sessionSummaries, for: serverId)
        
        // If the server supports session/list, prefer server-provided timestamps for grouping.
        // Only persist local activity timestamps for servers that lack session/list.
        let supportFlag = sessionListSupportFlag(for: serverId)
        let touchLocalTimestamp = (supportFlag == false)
        debugLog("bumpSessionTimestamp sessionId=\(sessionId.prefix(8)) touchUpdatedAt=\(touchLocalTimestamp) sessionListSupport=\(supportFlag.map(String.init) ?? "nil")")
        storage.updateSession(sessionId: sessionId, forServerId: serverId, title: nil, touchUpdatedAt: touchLocalTimestamp)
    }

    /// Persist chat messages to Core Data for a session.
    func persistChatToStorage(serverId: UUID, sessionId: String) {
        // Only persist for agents without session/load support
        guard canLoadSession(for: serverId) == false else { return }

        // Only persist non-streaming, completed messages
        let messagesToStore = sessionViewModel?.chatMessages.filter { !$0.isStreaming } ?? []
        guard !messagesToStore.isEmpty else { return }

        let storedMessages = messagesToStore.map { $0.toStoredInfo() }
        storage.saveMessages(storedMessages, forSessionId: sessionId, serverId: serverId)
    }

    /// Load chat messages from Core Data for a session.
    func loadChatFromStorage(sessionId: String, serverId: UUID) -> [ChatMessage] {
        let storedMessages = storage.fetchMessages(forSessionId: sessionId, serverId: serverId)
        return storedMessages.map { ChatMessage(from: $0) }
    }

    /// Updates the session title for the current session if it hasn't been set yet.
    /// Uses the first user message (truncated to 30 chars) as the title.
    private func updateSessionTitleIfNeeded(with text: String) {
        guard let serverId = selectedServerId, !sessionId.isEmpty else { return }
        // Only update if the current session has no title
        guard let index = sessionSummaries.firstIndex(where: { $0.id == sessionId }),
              sessionSummaries[index].title == nil else { return }
        
        // Create a title from the text (truncated if needed)
        let maxLength = 30
        var title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count > maxLength {
            title = String(title.prefix(maxLength)) + "…"
        }
        
        // Update the session summary with the new title, preserving cwd and updatedAt
        let existingSession = sessionSummaries[index]
        sessionSummaries[index] = SessionSummary(id: sessionId, title: title, cwd: existingSession.cwd, updatedAt: existingSession.updatedAt)
        setSessionSummaries(sessionSummaries, for: serverId)
        
        // Persist the title, but don't stomp server timestamps for session/list-capable agents.
        let supportFlag = sessionListSupportFlag(for: serverId)
        let touchLocalTimestamp = (supportFlag == false)
        debugLog("updateSessionTitleIfNeeded sessionId=\(sessionId.prefix(8)) touchUpdatedAt=\(touchLocalTimestamp) sessionListSupport=\(supportFlag.map(String.init) ?? "nil") title=\(title)")
        storage.updateSession(sessionId: sessionId, forServerId: serverId, title: title, touchUpdatedAt: touchLocalTimestamp)
    }

    private func cacheUpdates() {
        guard let serverId = selectedServerId else { return }
        updatesCache[serverId] = updates
    }

    private func cacheInitializationSummary() {
        guard let serverId = selectedServerId else { return }
        initializationCache[serverId] = initializationSummary
    }

    /// Persist all in-memory sessions to Core Data for a server.
    /// This is a safety net to ensure all sessions are persisted.
    /// Sessions are normally persisted immediately when created.
    private func persistSessionsToStorage(forServerId serverId: UUID) {
        let sessions = sessionSummaryCache[serverId] ?? sessionSummaries
        guard !sessions.isEmpty || sessionListSupportFlag(for: serverId) == true else { return }

        debugLogSessionStats(label: "persistSessionsToStorage input", sessions: sessions)
        
        for session in sessions {
            let storedInfo = StoredSessionInfo(
                sessionId: session.id,
                title: session.title,
                cwd: session.cwd,
                updatedAt: session.updatedAt
            )
            storage.saveSession(storedInfo, forServerId: serverId)
        }

        // For agents that support `session/list`, treat the fetched list as the source of truth
        // and prune stale cache entries (often legacy "New Chat" placeholders) so next startup
        // doesn't show dozens of phantom sessions.
        if sessionListSupportFlag(for: serverId) == true {
            let keep = Set(sessions.map(\.id))
            let deleted = storage.pruneSessions(forServerId: serverId, keeping: keep)
            debugLog("CoreData.pruneSessions deleted=\(deleted) keeping=\(keep.count)")
        }

        if devModeEnabled {
            let stored = storage.fetchSessions(forServerId: serverId).map { $0.toSessionSummary() }
            debugLogSessionStats(label: "CoreData.fetchSessions after persistSessionsToStorage", sessions: stored)
        }
    }

    private func loadPendingSessionIfPossible() {
        guard let serverId = selectedServerId else { return }
        guard connectionState == .connected else { return }

        let serverPendingSession = selectedServerViewModelAny?.pendingSessionLoad
        let pendingSessionId: String? = {
            if let pending = pendingSessionLoad, pending.serverId == serverId, !pending.sessionId.isEmpty {
                return pending.sessionId
            }
            if let serverPendingSession, !serverPendingSession.isEmpty {
                return serverPendingSession
            }
            return nil
        }()

        if let targetSession = pendingSessionId {
            // If session is still a local draft, skip loading but keep the pending load
            // so it can retry when the placeholder is migrated to a real session ID
            guard !pendingLocalSessions.contains(targetSession) else {
                return
            }

            if canLoadSession(for: serverId) {
                if selectedServerViewModelAny?.lastLoadedSession != targetSession || sessionViewModel?.chatMessages.isEmpty ?? true {
                    sendLoadSession(targetSession)
                }
            } else {
                setActiveSession(targetSession)
                pendingSessionLoad = nil
            }
        }

        // session/resume is currently triggered only as part of prompt preflight when supported.
    }

    // MARK: Actions

    func connect(completion: ((Bool) -> Void)? = nil) {
        if selectedServerId == nil, let firstId = servers.first?.id {
            selectServer(firstId)
        }
        persistActiveServerConfig()
        let normalized = normalizeEndpointInput(scheme: scheme, host: endpointHost)
        let urlString = "\(normalized.scheme)://\(normalized.host)"
        guard let url = URL(string: urlString) else {
            append("Invalid endpoint: \(urlString)")
            completion?(false)
            return
        }
        
        let effectiveClientId = cfAccessClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveClientSecret = cfAccessClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let requiresUnescapedSlashes = selectedServerId.flatMap { agentInfoCache[$0]?.requiresUnescapedSlashesInJSONRPC } ?? false
        
        let config = ACPConnectionConfig(
            endpoint: url,
            authToken: token.isEmpty ? nil : token,
            cloudflareAccessClientId: effectiveClientId.isEmpty ? nil : effectiveClientId,
            cloudflareAccessClientSecret: effectiveClientSecret.isEmpty ? nil : effectiveClientSecret,
            requiresUnescapedSlashes: requiresUnescapedSlashes,
            pingInterval: 15
        )
        
        pendingRequests.removeAll()
        if let serverId = selectedServerId {
            connectionManager.shouldAutoInitialize = initializedServers.contains(serverId)
        } else {
            connectionManager.shouldAutoInitialize = false
        }
        connectionManager.connect(config: config, completion: completion)
    }

    private func cloudflareAccessHeaders(cfClientId: String, cfClientSecret: String) -> [String: String] {
        var headers: [String: String] = [:]
        let trimmedId = cfClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = cfClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedId.isEmpty {
            headers["CF-Access-Client-Id"] = trimmedId
        }

        if !trimmedSecret.isEmpty {
            headers["CF-Access-Client-Secret"] = trimmedSecret
        }

        return headers
    }

    /// Builds the full set of additional headers for WebSocket connections.
    /// Includes the persistent X-Client-Id header and any Cloudflare Access headers.
    /// Note: For normal connections, ACPClientManager handles headers internally.
    /// This is only used by testConnection which creates a standalone ACPService.
    private func connectionHeaders(
        cfClientId: String,
        cfClientSecret: String
    ) -> [String: String] {
        var headers = cloudflareAccessHeaders(
            cfClientId: cfClientId.trimmingCharacters(in: .whitespacesAndNewlines),
            cfClientSecret: cfClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        // Use the same persistent clientId from connectionManager for consistency
        headers["X-Client-Id"] = connectionManager.clientId
        return headers
    }

    func connectAndWait() async -> Bool {
        // Build the connection config
        let normalized = normalizeEndpointInput(scheme: scheme, host: endpointHost)
        let urlString = "\(normalized.scheme)://\(normalized.host)"
        guard let url = URL(string: urlString) else {
            append("Invalid endpoint: \(urlString)")
            return false
        }
        
        let trimmedClientId = cfAccessClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientSecret = cfAccessClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let requiresUnescapedSlashes = selectedServerId.flatMap { agentInfoCache[$0]?.requiresUnescapedSlashesInJSONRPC } ?? false
        
        let config = ACPConnectionConfig(
            endpoint: url,
            authToken: token.isEmpty ? nil : token,
            cloudflareAccessClientId: trimmedClientId.isEmpty ? nil : trimmedClientId,
            cloudflareAccessClientSecret: trimmedClientSecret.isEmpty ? nil : trimmedClientSecret,
            requiresUnescapedSlashes: requiresUnescapedSlashes,
            pingInterval: 15
        )
        
        pendingRequests.removeAll()
        if let serverId = selectedServerId {
            connectionManager.shouldAutoInitialize = initializedServers.contains(serverId)
        } else {
            connectionManager.shouldAutoInitialize = false
        }
        return await connectionManager.connectAndWait(config: config)
    }

    /// Verify the WebSocket is alive; if not, cleanly reconnect.
    private func verifyConnectionHealth() async {
        await connectionManager.verifyConnectionHealth()
    }

    func resumeConnectionIfNeeded() {
        guard isNetworkAvailable else { return }
        guard !isConnecting else { return }

        let now = Date()
        if let last = lastResumeRefreshAt, now.timeIntervalSince(last) < 1 {
            return
        }
        lastResumeRefreshAt = now

        resumeRefreshTask?.cancel()
        resumeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.resumeRefreshTask = nil }
            await self.refreshSessionsAfterResume()
        }
    }

    func initializeAndWait() async -> Bool {
        guard let serverId = selectedServerId else { return false }
        initializedServers.insert(serverId)
        connectionManager.shouldAutoInitialize = true
        let payload = makeInitializationPayload()
        return await connectionManager.initializeAndWait(payload: payload)
    }

    func sendInitialize() {
        Task { @MainActor in
            _ = await initializeAndWait()
        }
    }

    func disconnect() {
        resumeRefreshTask?.cancel()
        resumeRefreshTask = nil
        persistCurrentServerState()
        sessionViewModel?.resetStreamingState()
        if let serverId = selectedServerId {
            serverLifecycleController.enqueuePendingDisconnect(serverId)
        }
        connectionManager.disconnect()
    }

    /// On iOS, long background periods frequently abort existing WebSocket connections.
    /// This path validates the socket and then forces a session refresh so the UI recovers
    /// without requiring a manual pull-to-refresh.
    @MainActor
    private func refreshSessionsAfterResume() async {
        guard isNetworkAvailable else {
            loadCachedSessions()
            return
        }

        // If we believe we're connected, verify the socket before issuing ACP requests.
        if connectionState == .connected {
            await connectionManager.verifyConnectionHealth()
        }

        if connectionState != .connected {
            let connected = await connectAndWait()
            guard connected else {
                loadCachedSessionsWithMessage()
                return
            }
        }

        if selectedServerId != nil, !isInitializedOnConnection {
            _ = await initializeAndWait()
        }

        let canForceFetch = selectedServerId.map { sessionListSupportFlag(for: $0) != false } ?? true
        fetchSessionList(force: canForceFetch)

        // Fetch models for Codex servers after initialization
        if let codexServer = selectedServerViewModelAny as? CodexServerViewModel {
            codexServer.fetchModels()
            codexServer.resubscribeActiveSessionAfterReconnect()
        }
    }

    private func makeInitializationPayload() -> ACPInitializationPayload {
        let clientCapabilities: [String: ACP.Value] = [
            "fs": .object([
                "readTextFile": .bool(supportsFSRead),
                "writeTextFile": .bool(supportsFSWrite)
            ]),
            "terminal": .bool(supportsTerminal),
        ]

        // Codex app-server capabilities (separate from ACP clientCapabilities)
        let capabilities: [String: ACP.Value] = [
            "experimentalApi": .bool(true),
        ]

        return ACPInitializationPayload(
            protocolVersion: 1,
            clientName: clientName,
            clientVersion: clientVersion,
            clientCapabilities: clientCapabilities,
            capabilities: capabilities
        )
    }

    func sendNewSession(workingDirectory: String? = nil) {
        // Phase 2: Delegate to ServerViewModel (supports both ACP and Codex servers)
        guard let serverViewModel = selectedServerViewModelAny else { return }
        serverViewModel.sendNewSession(workingDirectory: workingDirectory)
    }

    /// Update the working directory for a pending (local-only) session.
    func updatePendingSessionWorkingDirectory(_ newValue: String) {
        guard isPendingSession else { return }
        let sanitized = sanitizeWorkingDirectory(newValue)
        pendingLocalSessionCwds[sessionId] = sanitized
        
        guard let serverId = selectedServerId else { return }
        rememberUsedWorkingDirectory(sanitized, forServerId: serverId)
        
        if let index = sessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            let existing = sessionSummaries[index]
            sessionSummaries[index] = SessionSummary(
                id: existing.id,
                title: existing.title,
                cwd: sanitized,
                updatedAt: existing.updatedAt
            )
        }
        sessionSummaryCache[serverId] = sessionSummaries
    }

    /// Load an existing session from the server using session/load.
    /// This is only called when cache is empty (e.g., fresh app launch).
    /// - Parameters:
    ///   - sessionIdToLoad: The session ID to load
    ///   - cwd: Optional working directory for the session. If nil, uses the session's stored CWD or falls back to default.
    func sendLoadSession(_ sessionIdToLoad: String, cwd: String? = nil) {
        // Phase 2: Delegate to ServerViewModel
        guard let serverViewModel = selectedServerViewModel else {
            append("No server selected")
            return
        }
        serverViewModel.sendLoadSession(sessionIdToLoad, cwd: cwd)

        // Sync pending load state
        pendingSessionLoad = nil
    }

    func fetchSessionList(force: Bool = false) {
        // Phase 2: Delegate to ServerViewModel
        selectedServerViewModelAny?.fetchSessionList(force: force)
    }

    /// Refresh sessions - reconnect if needed and fetch list.
    func refreshSessions() async {
        if connectionState != .connected {
            let connected = await connectAndWait()
            guard connected else {
                loadCachedSessions()
                return
            }
            if selectedServerId != nil, !isInitializedOnConnection {
                _ = await initializeAndWait()
            }
        }
        fetchSessionList(force: true)
    }

    /// Send session/list request to the server.
    private func sendSessionList(service: ACPService) {
        Task { @MainActor in
            do {
                let payload = ACPSessionListPayload(workingDirectory: effectiveWorkingDirectory(resolvedWorkingDirectory))
                _ = try await service.listSessions(payload)
            } catch {
                append("Failed to fetch sessions: \(error)")
            }
        }
    }
    
    /// Send session/list requests for all used working directories and merge results.
    /// Used for agents like qwen-code that require working directory for session listing.
    private func sendSessionListForAllWorkingDirectories(service: ACPService, serverId: UUID) {
        // Guard against duplicate fetches - if one is already in progress, skip
        if pendingMultiCwdFetch[serverId] != nil {
            append("Multi-CWD fetch already in progress, skipping duplicate request")
            return
        }
        
        // Get all used working directories, always include the current default
        var directories = storage.fetchUsedWorkingDirectories(forServerId: serverId)
        if !directories.contains(resolvedWorkingDirectory) {
            directories.insert(resolvedWorkingDirectory, at: 0)
        }
        
        // Safety check - should never happen after the insert above
        guard !directories.isEmpty else {
            append("No working directories to fetch sessions for")
            return
        }
        
        append("Fetching sessions for \(directories.count) working director\(directories.count == 1 ? "y" : "ies"): \(directories.joined(separator: ", "))")
        
        // Set up the pending multi-fetch tracker
        pendingMultiCwdFetch[serverId] = (remaining: directories.count, sessions: [])
        
        Task { @MainActor in
            for directory in directories {
                do {
                    let payload = ACPSessionListPayload(workingDirectory: effectiveWorkingDirectory(directory))
                    _ = try await service.listSessions(payload)
                } catch {
                    append("Failed to fetch sessions for \(directory): \(error)")
                    // Decrement the remaining count on error
                    if var pending = pendingMultiCwdFetch[serverId] {
                        pending.remaining -= 1
                        if pending.remaining <= 0 {
                            // All done, finalize
                            finalizeMultiCwdFetch(serverId: serverId)
                        } else {
                            pendingMultiCwdFetch[serverId] = pending
                        }
                    }
                }
            }
        }
    }
    
    /// Finalize a multi-CWD fetch by deduplicating, sorting, and caching results.
    private func finalizeMultiCwdFetch(serverId: UUID) {
        guard let pending = pendingMultiCwdFetch.removeValue(forKey: serverId) else { return }

        debugLogSessionStats(label: "session/list multi-CWD merged", sessions: pending.sessions)
        setSessionSummaries(pending.sessions, for: serverId)
        debugLogSessionStats(label: "session/list multi-CWD after setSessionSummaries", sessions: sessionSummaries)
        persistSessionsToStorage(forServerId: serverId)
        append("Fetched \(sessionSummaries.count) unique sessions across working directories")
    }

    /// Load cached sessions and display a message.
    private func loadCachedSessionsWithMessage() {
        loadCachedSessions()
        if sessionSummaries.isEmpty {
            append("No cached sessions; create a new one.")
        } else {
            if let serverId = selectedServerId {
                let canLoad = canLoadSession(for: serverId)
                let canResume = canResumeSession(for: serverId)
                if canLoad {
                    append("Loaded \(sessionSummaries.count) cached session(s) - can resume via session/load")
                } else if canResume {
                    append("Loaded \(sessionSummaries.count) cached session(s) - can resume via session/resume")
                } else {
                    append("Loaded \(sessionSummaries.count) cached session(s) - sessions are ephemeral (no session/load or session/resume support)")
                }
            }
        }
    }

    /// Open a session - delegates to ServerViewModel (Phase 2 migration).
    /// Works for both ACP and Codex servers via protocol.
    func openSession(_ id: String) {
        // Use protocol to support both ACP and Codex servers
        if let serverViewModel = selectedServerViewModel {
            serverViewModel.openSession(id)
        } else if let codexViewModel = selectedCodexServerViewModel {
            codexViewModel.openSession(id)
        }
    }

    // Phase 2: sendPrompt has been moved to ServerViewModel
    // UI should call selectedServerViewModel?.sendPrompt(promptText:images:commandName:) instead

    private func finalizePendingSessionCreation(response: ACP.AnyResponse, placeholderId: String, fallbackCwd: String) {
        // Guard against duplicate finalization - this can happen if handleIncoming()
        // processes the session/new response before the Task continuation returns
        let isPending = pendingLocalSessions.contains(placeholderId)
        debugLog("finalizePendingSessionCreation called for placeholderId=\(placeholderId), isPending=\(isPending)")
        guard isPending else {
            debugLog("Session \(placeholderId) already finalized, skipping duplicate finalizePendingSessionCreation")
            return
        }

        pendingLocalSessionCwds.removeValue(forKey: placeholderId)

        // Use ACPSessionResponseParser for typed parsing.
        // IMPORTANT: Don't pass fallbackSessionId to avoid silently using the placeholder
        // when the server's response should contain the real session ID.
        let parsed = ACPSessionResponseParser.parseSessionNew(
            result: response.resultValue,
            fallbackCwd: pendingNewSessionCwd ?? fallbackCwd
        )

        // Use the server-returned session ID if available, otherwise keep placeholder
        let resolvedId: String
        if let serverSessionId = parsed?.sessionId, !serverSessionId.isEmpty {
            resolvedId = serverSessionId
        } else {
            // Parsing failed - try direct extraction as fallback
            // This indicates the response doesn't match expected ACP format
            debugLog("Warning: ACPSessionResponseParser failed to extract sessionId, falling back to direct extraction")
            let directSessionId = response.resultValue?.objectValue?["sessionId"]?.stringValue
                ?? response.resultValue?.objectValue?["session"]?.stringValue
                ?? response.resultValue?.objectValue?["id"]?.stringValue

            if let directId = directSessionId, !directId.isEmpty {
                debugLog("Direct extraction found sessionId: \(directId)")
                resolvedId = directId
            } else {
                // Server didn't return a session ID - this shouldn't happen per ACP spec
                // but we handle gracefully by keeping the placeholder
                resolvedId = placeholderId
                debugLog("Warning: session/new response missing sessionId, keeping placeholder: \(placeholderId)")
            }
        }

        let resolvedCwd = parsed?.cwd ?? fallbackCwd
        let modesInfo = parsed?.modes

        pendingLocalSessions.remove(placeholderId)
        pendingNewSessionCwd = nil
        pendingNewSessionPlaceholderId = nil

        // Record the placeholder → resolved ID mapping for sendPrompt to use
        // This ensures the correct session ID is used even if there's a race condition
        // between handleIncoming and the Task continuation.
        // Only set if not already mapped (idempotent) to avoid overwriting a valid mapping.
        if resolvedId != placeholderId {
            if resolvedSessionIds[placeholderId] == nil {
                resolvedSessionIds[placeholderId] = resolvedId
            } else {
                // This indicates a serious bug - same placeholder resolved multiple times to different IDs
                let originalResolvedId = resolvedSessionIds[placeholderId]!
                let message = "ERROR: Placeholder \(placeholderId) already resolved to \(originalResolvedId), attempted to overwrite with \(resolvedId). This indicates non-idempotent session/new handling or race condition."
                debugLog(message)
            }
        }

        if let serverId = selectedServerId, resolvedId != placeholderId {
            migrateSessionCaches(for: serverId, from: placeholderId, to: resolvedId)
        }

        setActiveSession(resolvedId, cwd: resolvedCwd, modes: modesInfo)
        if resolvedId != placeholderId {
            removePlaceholderSession(placeholderId, replacedBy: resolvedId)
        }
    }

    /// Remove a local-only placeholder session and clean all caches.
    private func removePlaceholderSession(_ placeholderId: String, replacedBy resolvedId: String?) {
        guard let serverId = selectedServerId else { return }

        if let resolvedId, resolvedId != placeholderId {
            migrateStoredSession(for: serverId, from: placeholderId, to: resolvedId)
        }

        pendingLocalSessions.remove(placeholderId)
        pendingLocalSessionCwds.removeValue(forKey: placeholderId)

        // Update last session cache if it still points to the placeholder.
        if sessionCache[serverId] == placeholderId {
            sessionCache[serverId] = resolvedId ?? ""
        }
        if pendingSessionLoad?.sessionId == placeholderId {
            pendingSessionLoad = nil
        }

        sessionSummaries.removeAll { $0.id == placeholderId }
        setSessionSummaries(sessionSummaries, for: serverId)

        clearCache(for: serverId, sessionId: placeholderId)
        sessionViewModel?.removeCommands(for: serverId, sessionId: placeholderId)

        storage.deleteSession(sessionId: placeholderId, forServerId: serverId)
    }

    private func migrateSessionCaches(for serverId: UUID, from placeholderId: String, to resolvedId: String) {
        guard placeholderId != resolvedId else { return }
        migrateCache(serverId: serverId, from: placeholderId, to: resolvedId)

        // Phase 2: Migrate the session view model instance via ServerViewModel
        migrateSessionViewModel(from: placeholderId, to: resolvedId)

        // Migrate caches within the session view model via ServerViewModel
        if let viewModel = selectedServerViewModelAny?.currentSessionViewModel {
            viewModel.migrateSessionCommandsCache(for: serverId, from: placeholderId, to: resolvedId)
            viewModel.migrateSessionModeCache(for: serverId, from: placeholderId, to: resolvedId)
        }
    }

    private func migrateStoredSession(for serverId: UUID, from placeholderId: String, to resolvedId: String) {
        guard placeholderId != resolvedId else { return }

        let placeholderSession = storage.fetchSessions(forServerId: serverId).first(where: { $0.sessionId == placeholderId })
        if let placeholderSession {
            storage.saveSession(
                StoredSessionInfo(
                    sessionId: resolvedId,
                    title: placeholderSession.title,
                    cwd: placeholderSession.cwd,
                    updatedAt: placeholderSession.updatedAt
                ),
                forServerId: serverId
            )
        } else {
            // Ensure the destination session exists before saving messages.
            storage.saveSession(
                StoredSessionInfo(sessionId: resolvedId, title: nil, cwd: nil, updatedAt: nil),
                forServerId: serverId
            )
        }

        let messages = storage.fetchMessages(forSessionId: placeholderId, serverId: serverId)
        if !messages.isEmpty {
            storage.saveMessages(messages, forSessionId: resolvedId, serverId: serverId)
        }
    }

    private func failPendingTurn(_ message: String) {
        sessionViewModel?.abandonStreamingMessage()
        sessionViewModel?.addSystemErrorMessage(message)
    }

    func sendCancel() {
        guard let service else { return }
        guard !sessionId.isEmpty else {
            append("No session to cancel")
            return
        }
        // Cancel any pending permission requests for this session
        sessionViewModel?.cancelPendingPermissionRequests(for: sessionId)
        
        let payload = ACPSessionCancelPayload(sessionId: sessionId)

        Task { @MainActor in
            do {
                _ = try await service.cancelSession(payload)
            } catch {
                append("Failed to cancel session: \(error)")
            }
        }
        sessionViewModel?.abandonStreamingMessage()
    }

    /// Set the session mode for the current session.
    func sendSetMode(_ modeId: String) {
        sessionViewModel?.sendSetMode(
            modeId,
            sessionId: sessionId,
            serverId: selectedServerId
        )
    }

    /// Respond to a pending permission request with the user's choice.
    func sendPermissionResponse(requestId: ACP.ID, optionId: String) {
        sessionViewModel?.sendPermissionResponse(requestId: requestId, optionId: optionId)
    }

    /// Codex JSON-RPC path shim (should be unused for ACP-native sessions).
    func sendPermissionResponse(requestId: JSONRPCID, optionId: String) {
        sessionViewModel?.sendPermissionResponse(requestId: requestId.acpID, optionId: optionId)
    }

    private func sendRawRequest(method: String, params: ACP.Value, service: ACPService, asNotification: Bool = false) {
        let id: ACP.ID = .string(UUID().uuidString.prefix(8).description)
        let message: ACPWireMessage
        if asNotification {
            message = .notification(.init(method: method, params: params))
        } else {
            message = .request(.init(id: id, method: method, params: params))
            pendingRequests[id] = method
        }

        Task { @MainActor in
            do {
                try await service.sendMessage(message)
                logWire("→", message: message)
            } catch {
                append("Send error (\(method)): \(error)")
            }
        }
    }

    // MARK: - ACPClientManagerDelegate

    func clientManager(_ manager: ACPClientManager, willSendRequest request: ACP.AnyRequest) {
        pendingRequests[request.id] = request.method
        logWire("→", message: .request(request))
    }

    func clientManager(_ manager: ACPClientManager, didReceiveMessage message: ACPWireMessage) {
        handleIncoming(message)
    }

    func clientManager(_ manager: ACPClientManager, didReceiveNotification notification: ACP.AnyMessage) {
        // Notifications are surfaced through didReceiveMessage; no-op to avoid duplication.
    }

    func clientManager(_ manager: ACPClientManager, didChangeState state: ACPConnectionState) {
        append("State: \(stateLabel(state))")
        switch state {
        case .connected:
            if pendingNetworkRefresh {
                pendingNetworkRefresh = false
                resumeConnectionIfNeeded()
            }
        case .failed:
            _ = serverLifecycleController.popPendingDisconnectServerId() ?? selectedServerId
        case .disconnected:
            _ = serverLifecycleController.popPendingDisconnectServerId() ?? selectedServerId
        case .connecting:
            break
        }
    }

    func clientManager(_ manager: ACPClientManager, didChangeNetworkAvailability available: Bool) {
        append("Network: \(available ? "available" : "unavailable")")
        if available {
            pendingNetworkRefresh = true
            if connectionState == .connected {
                pendingNetworkRefresh = false
                resumeConnectionIfNeeded()
            }
        } else {
            pendingNetworkRefresh = false
        }
    }

    func clientManager(_ manager: ACPClientManager, didEncounterError error: any Error) {
        append("Error: \(error)")
    }

    func clientManager(_ manager: ACPClientManager, didLog message: String) {
        append(message)
    }

    func clientManager(_ manager: ACPClientManager, didCreateService service: ACPService) {
        // Service is now managed by the connectionManager
    }

    // MARK: - Testing Helpers

    /// Simulates receiving an ACP message for testing purposes.
    /// This routes through the same path as messages received through the connection manager.
    func acpService(_ service: ACPService, didReceiveMessage message: ACPWireMessage) {
        clientManager(connectionManager, didReceiveMessage: message)
    }

    /// Simulates an outgoing request for testing purposes.
    /// This routes through the same path as requests sent through the connection manager.
    func acpService(_ service: ACPService, willSend request: ACP.AnyRequest) {
        clientManager(connectionManager, willSendRequest: request)
    }

    /// Sets a service for testing purposes.
    /// This injects a service directly into the connection manager for tests that need
    /// to verify actual message sending.
    func setServiceForTesting(_ service: ACPService?) {
        connectionManager.setServiceForTesting(service)
    }

    private func applyInitializeResult(_ parsed: ACPInitializeResult, serverId: UUID) {
        switch parsed.connectedProtocol {
        case .codexAppServer:
            guard let userAgent = parsed.userAgent, let agentInfo = parsed.agentInfo else { return }
            connectedProtocols[serverId] = .codexAppServer

            // Switch to CodexServerViewModel if not already
            if serverViewModels[serverId] is ServerViewModel {
                switchToCodexServerViewModel(for: serverId)
            }

            agentInfoCache[serverId] = agentInfo
            serverViewModels[serverId]?.updateAgentInfo(agentInfo)
            refreshImageAttachmentSupport(for: serverId)

            initializationSummary = "\(agentInfo.displayNameWithVersion) (initialized)"

            if let codexVM = serverViewModels[serverId] as? CodexServerViewModel {
                codexVM.markInitializedAckNeeded()
            } else {
                codexAckNeeded.insert(serverId)
            }
            append("Detected Codex app-server (\(userAgent))")
        case .acp, .none:
            connectedProtocols[serverId] = .acp
            serverViewModels[serverId]?.updateConnectedProtocol(.acp)
            codexAckNeeded.remove(serverId)
            guard let agentInfo = parsed.agentInfo else { return }
            agentInfoCache[serverId] = agentInfo
            serverViewModels[serverId]?.updateAgentInfo(agentInfo)
            refreshImageAttachmentSupport(for: serverId)

            applyEncodingRequirements(for: agentInfo, service: service, log: true)

            initializationSummary = agentInfo.displayNameWithVersion + " (initialized)"
            append(AgentInfoDiagnostics.capabilitySummary(for: agentInfo))

            if !agentInfo.modes.isEmpty {
                availableModes = agentInfo.modes
                if let currentMode = parsed.currentModeId {
                    // Store the default mode on ServerViewModel for new sessions
                    selectedServerViewModelAny?.setDefaultModeId(currentMode)
                    sessionViewModel?.setCurrentModeId(currentMode)
                }
                append("Modes: \(agentInfo.modes.map { $0.name }.joined(separator: ", ")), current: \(sessionViewModel?.currentModeId ?? "none")")
            }
        }

        objectWillChange.send()
    }

    private func handleIncoming(_ message: ACPWireMessage) {
        logWire("←", message: message)
        switch message {
        case .response(let response):
            let method = pendingRequests.removeValue(forKey: response.id)
            append(renderResponse(response, method: method))

            if let error = response.errorValue {
                let errorActions = ACPResponseDispatcher.dispatchError(
                    code: error.code,
                    message: error.message,
                    method: method
                )
                for action in errorActions {
                    applyResponseAction(action, method: method)
                }

                if method == "session/load" && error.code == -32601 {
                    pendingSessionLoad = nil
                }
                if method == "session/list" {
                    if let serverId = selectedServerId {
                        persistSessionsToStorage(forServerId: serverId)
                    }
                    loadCachedSessionsWithMessage()
                }
                return
            }

            // Build dispatch context
            let context = ACPResponseDispatchContext(
                pendingPlaceholderId: pendingNewSessionPlaceholderId,
                pendingCwd: pendingNewSessionCwd,
                cwdTransform: { cwd in
                    guard let cwd else { return nil }
                    return cwd
                }
            )
            
            // Clear pending state for session/new
            if method == "session/new" || method == "session/create" {
                pendingNewSessionCwd = nil
                pendingNewSessionPlaceholderId = nil
            }
            
            // Dispatch and apply actions
            let actions = ACPResponseDispatcher.dispatchSuccess(
                result: response.resultValue,
                method: method,
                context: context
            )
            for action in actions {
                applyResponseAction(action, method: method)
            }
            
            // Handle initialize continuation and side effects
            if method == "initialize" || method == "acp/initialize" ||
               response.resultValue?.objectValue?["agent"] != nil ||
               response.resultValue?.objectValue?["agentInfo"] != nil {
                cacheInitializationSummary()
                // Only auto-open last session on initial app launch, not on every server switch
                if isInitialAppLaunch {
                    ensureSessionForActiveServer()
                    isInitialAppLaunch = false
                }
                fetchSessionList()
                loadPendingSessionIfPossible()
            }
            
        case .notification(let notification):
            append(render("Notification", method: notification.method, payload: notification.params))
            if connectedProtocols[selectedServerId ?? UUID()] == .codexAppServer {
                selectedCodexServerViewModel?.handleCodexMessage(JSONRPCMessage(message))
            }
            if notification.method == "session/update" {
                let summary = ACPSessionUpdateParser.summarize(params: notification.params) { [weak self] update in
                    guard let self else { return "{}" }
                    return ACPMessageFormatter.compact(update, encoder: self.encoder)
                }
                append(summary)
                handleChatUpdate(notification.params)
            }
        case .request(let request):
            append(render("Request", method: request.method, payload: request.params))
            if connectedProtocols[selectedServerId ?? UUID()] == .codexAppServer {
                selectedCodexServerViewModel?.handleCodexMessage(JSONRPCMessage(message))
                if request.method == "item/commandExecution/requestApproval"
                    || request.method == "item/fileChange/requestApproval" {
                    Task { @MainActor in
                        let jsonRequest = JSONRPCRequest(request)
                        await selectedCodexServerViewModel?.handleApprovalRequest(jsonRequest)
                    }
                    return
                }
                if request.method == "item/tool/requestUserInput" {
                    // Already handled by handleCodexMessage → handleRequestUserInput
                    return
                }
            }
            if request.method == "session/request_permission" {
                sessionViewModel?.handlePermissionRequest(request)
            } else if request.method == "fs/read_text_file" {
                sessionViewModel?.handleFSReadRequest(request)
            } else if request.method == "fs/write_text_file" {
                sessionViewModel?.handleFSWriteRequest(request)
            } else if request.method == "terminal/create" || request.method == "terminal/write" || request.method == "terminal/resize" || request.method == "terminal/release" {
                sessionViewModel?.handleTerminalRequest(request)
            } else {
                // Unknown request - send method not found error
                sessionViewModel?.sendErrorResponse(to: request.id, code: -32601, message: "Method not found: \(request.method)")
            }
        }
    }
    
    // MARK: - Response Action Application
    
    private func applyResponseAction(_ action: ACPResponseAction, method: String?) {
        guard let serverId = selectedServerId else { return }
        
        switch action {
        case .sessionMigrated(let from, let to):
            debugLog("applyResponseAction: sessionMigrated from \(from) to \(to)")
            migrateSessionCaches(for: serverId, from: from, to: to)

        case .sessionActivated(let activation):
            debugLog("applyResponseAction: sessionActivated with \(activation.sessionId)")
            setActiveSession(activation.sessionId, cwd: activation.cwd, modes: activation.modes)
            
        case .sessionMaterialized(let sessionId):
            connectionManager.markSessionMaterialized(sessionId)
            
        case .modeChanged(let modeId):
            sessionViewModel?.setCurrentModeId(modeId)
            sessionViewModel?.cacheCurrentMode(serverId: serverId, sessionId: sessionId)
            append("Mode changed to: \(modeId)")

        case .initialized(let result):
            applyInitializeResult(result, serverId: serverId)

        case .stopReason(let reason):
            // Delegate to sessionViewModel for session-scoped handling
            sessionViewModel?.handleStopReason(reason, serverId: serverId, sessionId: sessionId)

        case .sessionListReceived(let listResult):
            applySessionListResult(listResult, serverId: serverId)

        case .sessionLoadCompleted:
            // Delegate to sessionViewModel for session-scoped handling
            sessionViewModel?.handleSessionLoadCompleted(serverId: serverId, sessionId: sessionId)

        case .capabilityConfirmed(let capability):
            applyCapabilityChange(capability, enabled: true, serverId: serverId)
            
        case .capabilityDisabled(let capability):
            applyCapabilityChange(capability, enabled: false, serverId: serverId)
            append("\(capability.rawValue) disabled for this agent (Method not found)")
            
        case .rpcError(let errorInfo):
            // Error was already logged; nothing additional to do
            break
        }
    }
    
    private func applySessionListResult(_ result: ACPSessionListResult, serverId: UUID) {
        // Delegate to ServerViewModel to handle multi-CWD fetch tracking
        serverViewModels[serverId]?.handleSessionListResult(result.sessions)
    }
    
    private func applyCapabilityChange(_ capability: ACPCapabilityKind, enabled: Bool, serverId: UUID) {
        guard var agentInfo = agentInfoCache[serverId] else { return }

        switch capability {
        case .listSessions:
            agentInfo.capabilities.listSessions = enabled
        case .loadSession:
            agentInfo.capabilities.loadSession = enabled
        case .resumeSession:
            agentInfo.capabilities.resumeSession = enabled
        }

        agentInfoCache[serverId] = agentInfo
        serverViewModels[serverId]?.updateAgentInfo(agentInfo)
    }

    private func handleChatUpdate(_ params: ACP.Value?) {
        guard let updateSessionId = ACPSessionUpdateHandler.sessionId(from: params),
              updateSessionId == sessionId else { return }

        bumpSessionTimestamp(sessionId: updateSessionId)

        // Session events are now routed through sessionViewModel
        // which notifies back via ACPSessionEventDelegate
        sessionViewModel?.handleSessionUpdateEvents(
            params,
            activeSessionId: sessionId,
            serverId: selectedServerId
        )
    }


    /// Format a prompt error for user display.
    private func formatPromptError(_ error: Error) -> String {
        if let serviceError = error as? ACPServiceError {
            switch serviceError {
            case .rpc(_, let rpcError):
                return rpcError.message
            case .disconnected:
                return "Connection lost. Please reconnect and try again."
            case .unsupportedMessage:
                return "Received an unsupported response from the server."
            }
        }
        return "Failed to send message: \(error.localizedDescription)"
    }

    private enum TimeoutError: Error { case timedOut }

    /// Run an async operation with a simple timeout.
    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError.timedOut
            }

            guard let result = try await group.next() else {
                throw TimeoutError.timedOut
            }
            group.cancelAll()
            return result
        }
    }

    private func setActiveSession(_ id: String, cwd: String? = nil, modes: ACPModesInfo? = nil) {
        // Phase 2: Delegate to ServerViewModel
        guard let serverViewModel = selectedServerViewModel else { return }
        serverViewModel.setActiveSession(id, cwd: cwd, modes: modes)

        // Sync AppViewModel state with ServerViewModel
        // Note: sessionId and selectedSessionId are now computed properties, no sync needed
        availableModes = serverViewModel.availableModes

        // Sync pending load state
        if let serverPendingLoad = serverViewModel.pendingSessionLoad,
           let serverId = selectedServerId {
            pendingSessionLoad = (serverId, serverPendingLoad)
        } else {
            pendingSessionLoad = nil
        }
    }

    private func renderResponse(_ response: ACP.AnyResponse, method: String?) -> String {
        let idLabel = ACPMessageFormatter.idString(response.id)
        if let error = response.errorValue {
            let body = ACPMessageFormatter.compact(error, encoder: encoder)
            return "Error response id=\(idLabel) \(method.map { "(\($0))" } ?? ""): \(body)"
        }
        if let payload = response.resultValue {
            return "Response id=\(idLabel) \(method.map { "(\($0))" } ?? ""): \(ACPMessageFormatter.compact(payload, encoder: encoder))"
        } else {
            return "Response id=\(idLabel) \(method.map { "(\($0))" } ?? "")"
        }
    }

    private func render(_ kind: String, method: String?, payload: ACP.Value?) -> String {
        let methodLabel = method.map { "\($0)" } ?? ""
        if let payload {
            return "\(kind) \(methodLabel): \(ACPMessageFormatter.compact(payload, encoder: encoder))"
        } else {
            return "\(kind) \(methodLabel)"
        }
    }

    private func startCodexLoggingIfNeeded() {
        guard codexSessionLoggingEnabled else { return }
        guard let codexVM = selectedCodexServerViewModel else { return }
        let sessionId = codexVM.sessionId
        guard !sessionId.isEmpty else { return }
        let cwd = codexVM.sessionSummaries.first(where: { $0.id == sessionId })?.cwd ?? codexVM.workingDirectory
        Task { await codexSessionLogger.startSession(sessionId: sessionId, endpoint: codexVM.endpointURLString, cwd: cwd) }
    }

    private func logWire(_ direction: String, message: ACPWireMessage) {
        let label: String?
        switch message {
        case .request(let request): label = request.method
        case .notification(let notification): label = notification.method
        case .response(let response): label = pendingRequests[response.id]
        }
        let body = JSONRPCFormatter.compact(message, encoder: encoder)
        if codexSessionLoggingEnabled,
           let serverId = selectedServerId,
           connectedProtocols[serverId] == .codexAppServer {
            let sessionId = selectedCodexServerViewModel?.sessionId
            Task {
                await codexSessionLogger.logWire(
                    direction: direction,
                    method: label,
                    message: body,
                    sessionId: sessionId?.isEmpty == false ? sessionId : nil
                )
            }
        }
        if let label {
            append("\(direction) \(label): \(body)")
        } else {
            append("\(direction) \(body)")
        }
    }

    private func logWire(_ direction: String, message: JSONRPCMessage) {
        let label: String?
        switch message {
        case .request(let request):
            label = request.method
        case .notification(let notification):
            label = notification.method
        case .response(let response):
            label = string(from: response.id)
        case .error(let error):
            label = error.id.map(string(from:))
        }
        let body = ACPMessageFormatter.compact(message, encoder: encoder)
        if codexSessionLoggingEnabled,
           let serverId = selectedServerId,
           connectedProtocols[serverId] == .codexAppServer {
            let sessionId = selectedCodexServerViewModel?.sessionId
            Task {
                await codexSessionLogger.logWire(
                    direction: direction,
                    method: label,
                    message: body,
                    sessionId: sessionId?.isEmpty == false ? sessionId : nil
                )
            }
        }
        if let label {
            append("\(direction) \(label): \(body)")
        } else {
            append("\(direction) \(body)")
        }
    }

    private func string(from id: JSONRPCID) -> String {
        switch id {
        case .string(let value): return value
        case .int(let value): return String(value)
        }
    }

    private func append(_ text: String) {
        let now = Date()
        let log = LogLine(id: UUID(), timestamp: now, message: text)
        updates.append(log)
        cacheUpdates()
    }

    func stateLabel(_ state: ACPConnectionState) -> String {
        switch state {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .failed(let error): return "Failed: \(error)"
        }
    }
    
    // MARK: - Agent Info Parsing

    private var currentConnectedProtocol: ACPConnectedProtocol? {
        guard let serverId = selectedServerId else { return nil }
        return connectedProtocols[serverId]
    }

}

/// Server protocol type - allows explicit selection instead of auto-detection.
enum ServerType: String, CaseIterable, Equatable {
    case acp = "acp"
    case codexAppServer = "codex"

    var displayName: String {
        switch self {
        case .acp: return "ACP"
        case .codexAppServer: return "Codex App-Server"
        }
    }

    var description: String {
        switch self {
        case .acp: return "Agent Client Protocol (Claude Code, Gemini CLI, etc.). Use Codex App-Server for OpenAI Codex."
        case .codexAppServer: return "OpenAI Codex app-server protocol"
        }
    }
}

struct ACPServerConfiguration: Identifiable, Equatable {
    let id: UUID
    var name: String
    var scheme: String
    var host: String
    var token: String
    var cfAccessClientId: String
    var cfAccessClientSecret: String
    var workingDirectory: String
    var serverType: ServerType

    var endpointURLString: String {
        "\(scheme)://\(host)"
    }

    /// Initialize with default serverType for backwards compatibility.
    init(
        id: UUID,
        name: String,
        scheme: String,
        host: String,
        token: String,
        cfAccessClientId: String,
        cfAccessClientSecret: String,
        workingDirectory: String,
        serverType: ServerType = .acp
    ) {
        self.id = id
        self.name = name
        self.scheme = scheme
        self.host = host
        self.token = token
        self.cfAccessClientId = cfAccessClientId
        self.cfAccessClientSecret = cfAccessClientSecret
        self.workingDirectory = workingDirectory
        self.serverType = serverType
    }
}

struct ValidatedServerConfiguration {
    let name: String
    let scheme: String
    let host: String
    let token: String
    let cfAccessClientId: String
    let cfAccessClientSecret: String
    let workingDirectory: String
    let serverType: ServerType
    let agentInfo: AgentProfile?
}

struct LogLine: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let message: String

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    var timestampLabel: String {
        Self.timestampFormatter.string(from: timestamp)
    }

    var title: String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: ": ") {
            return String(trimmed[..<range.lowerBound])
        }
        return trimmed
    }

    var details: String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: ": ") else { return nil }
        let remainder = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? nil : remainder
    }

    /// Attempts to pretty-print JSON details for easier reading.
    var prettyDetails: String? {
        guard
            let details = details,
            let data = details.data(using: .utf8),
            let jsonObject = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(jsonObject),
            let pretty = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted]),
            let string = String(data: pretty, encoding: .utf8)
        else { return nil }
        return string
    }

    var formattedLine: String {
        "[\(timestampLabel)] \(message)"
    }
}

// MARK: - ACPSessionCacheDelegate

extension AppViewModel {
    func saveMessages(_ messages: [ChatMessage], for serverId: UUID, sessionId: String) {
        var serverChats = chatCache[serverId] ?? [:]
        serverChats[sessionId] = messages
        chatCache[serverId] = serverChats
    }

    func loadMessages(for serverId: UUID, sessionId: String) -> [ChatMessage]? {
        return chatCache[serverId]?[sessionId]
    }

    func saveStopReason(_ reason: String, for serverId: UUID, sessionId: String) {
        var serverStops = stopReasonCache[serverId] ?? [:]
        serverStops[sessionId] = reason
        stopReasonCache[serverId] = serverStops
    }

    func loadStopReason(for serverId: UUID, sessionId: String) -> String? {
        return stopReasonCache[serverId]?[sessionId]
    }

    func clearCache(for serverId: UUID, sessionId: String) {
        var serverChats = chatCache[serverId] ?? [:]
        serverChats.removeValue(forKey: sessionId)
        chatCache[serverId] = serverChats

        var serverStops = stopReasonCache[serverId] ?? [:]
        serverStops.removeValue(forKey: sessionId)
        stopReasonCache[serverId] = serverStops
    }

    func clearCache(for serverId: UUID) {
        chatCache.removeValue(forKey: serverId)
        stopReasonCache.removeValue(forKey: serverId)
    }

    func migrateCache(serverId: UUID, from placeholderId: String, to resolvedId: String) {
        guard placeholderId != resolvedId else { return }

        // Migrate chat messages
        if var serverChats = chatCache[serverId], let placeholderChat = serverChats[placeholderId] {
            if serverChats[resolvedId]?.isEmpty != false {
                serverChats[resolvedId] = placeholderChat
            }
            chatCache[serverId] = serverChats
        }

        // Migrate stop reason
        if var serverStops = stopReasonCache[serverId], let stop = serverStops[placeholderId], serverStops[resolvedId] == nil {
            serverStops[resolvedId] = stop
            stopReasonCache[serverId] = serverStops
        }
    }

    func hasCachedMessages(serverId: UUID, sessionId: String) -> Bool {
        return chatCache[serverId]?[sessionId]?.isEmpty == false
    }

    func getLastMessagePreview(for serverId: UUID, sessionId: String) -> String? {
        guard let messages = chatCache[serverId]?[sessionId],
              let lastMessage = messages.last else { return nil }

        switch lastMessage.role {
        case .assistant:
            // Check for tool calls first
            if let lastToolCall = lastMessage.segments.last(where: { $0.kind == .toolCall }),
               let toolCall = lastToolCall.toolCall {
                return simplifyToolTitle(toolCall.title)
            }
            // Otherwise show text preview (truncated)
            let text = lastMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }
            return text.count > 60 ? String(text.prefix(60)) + "…" : text
        case .user:
            let text = lastMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }
            return "You: " + (text.count > 50 ? String(text.prefix(50)) + "…" : text)
        case .system:
            // Ignore system messages in preview (may contain verbose error text)
            return nil
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    private static let userMessageBegin = "## My request for Codex:"

    let id: UUID
    let role: Role
    var content: String
    var isStreaming: Bool
    var segments: [AssistantSegment]
    var images: [ChatImageData]
    var isError: Bool

    init(role: Role, content: String, isStreaming: Bool, segments: [AssistantSegment] = [], images: [ChatImageData] = [], isError: Bool = false) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.segments = segments
        self.images = images
        self.isError = isError
    }
    
    /// Initialize from stored message info (for restoring from Core Data).
    init(from stored: StoredMessageInfo) {
        self.id = stored.messageId
        self.role = Role(rawValue: stored.role) ?? .user
        self.content = ChatMessage.sanitizedUserContent(stored.content, role: self.role)
        self.isStreaming = false
        self.images = []
        self.segments = []
        self.isError = false
        
        // Decode segments if available
        if let segmentsData = stored.segmentsData,
           let decoded = try? JSONDecoder().decode([CodableSegment].self, from: segmentsData) {
            self.segments = decoded.map { $0.toSegment() }
        }
    }
    
    /// Convert to storable message info.
    func toStoredInfo(createdAt: Date = Date()) -> StoredMessageInfo {
        let segmentsData: Data?
        if !segments.isEmpty {
            let codableSegments = segments.map { CodableSegment(from: $0) }
            segmentsData = try? JSONEncoder().encode(codableSegments)
        } else {
            segmentsData = nil
        }
        
        return StoredMessageInfo(
            messageId: id,
            role: role.rawValue,
            content: content,
            createdAt: createdAt,
            segmentsData: segmentsData
        )
    }

    static func sanitizedUserContent(_ content: String, role: Role = .user) -> String {
        guard role == .user else { return content }
        guard let range = content.range(of: userMessageBegin) else { return content }
        let trimmed = content[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }
}

/// Codable version of AssistantSegment for persistence.
struct CodableSegment: Codable {
    let id: UUID
    let kind: String
    let text: String
    let toolCall: CodableToolCall?
    
    init(from segment: AssistantSegment) {
        self.id = segment.id
        self.kind = segment.kind.rawValue
        self.text = segment.text
        self.toolCall = segment.toolCall.map { CodableToolCall(from: $0) }
    }
    
    func toSegment() -> AssistantSegment {
        let segment = AssistantSegment(
            kind: AssistantSegment.Kind(rawValue: kind) ?? .message,
            text: text,
            toolCall: toolCall?.toToolCall()
        )
        return segment
    }
}

/// Codable version of ToolCallDisplay for persistence.
struct CodableToolCall: Codable {
    let toolCallId: String?
    let title: String
    let kind: String?
    let status: String?
    let output: String?
    
    init(from display: ToolCallDisplay) {
        self.toolCallId = display.toolCallId
        self.title = display.title
        self.kind = display.kind
        self.status = display.status
        self.output = display.output
        // Don't persist permission/approval data - they're transient
    }
    
    func toToolCall() -> ToolCallDisplay {
        ToolCallDisplay(
            toolCallId: toolCallId,
            title: title,
            kind: kind,
            status: status,
            output: output,
            permissionOptions: nil,
            acpPermissionRequestId: nil,
            permissionRequestId: nil,
            approvalRequestId: nil,
            approvalKind: nil,
            approvalReason: nil,
            approvalCommand: nil,
            approvalCwd: nil
        )
    }
}

struct AssistantSegment: Identifiable, Equatable {
    enum Kind: String, Codable {
        case message
        case thought
        case toolCall
        case plan
    }

    let id: UUID
    var kind: Kind
    var text: String
    var toolCall: ToolCallDisplay?

    init(kind: Kind, text: String = "", toolCall: ToolCallDisplay? = nil) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.toolCall = toolCall
    }
}

struct ToolCallDisplay: Equatable {
    var toolCallId: String?
    var title: String
    var kind: String?
    var status: String?
    var output: String?
    var permissionOptions: [ACPPermissionOption]?
    var acpPermissionRequestId: ACP.ID?
    var permissionRequestId: JSONRPCID?
    // Codex app-server approval requests (command/file) are separate from ACP permission requests.
    var approvalRequestId: JSONRPCID? = nil
    var approvalKind: String? = nil
    var approvalReason: String? = nil
    var approvalCommand: String? = nil
    var approvalCwd: String? = nil
}

// MARK: - Helper Extensions

extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        return self?.isEmpty ?? true
    }
}