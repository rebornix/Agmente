import Foundation
import SwiftUI
import Combine
import ACPClient
import ACP

/// Phase 2: ServerViewModel
/// Each server has its own ServerViewModel instance managing:
/// - Connection state and lifecycle
/// - Sessions for this server
/// - Server configuration
@MainActor
final class ServerViewModel: ObservableObject, Identifiable, ServerViewModelProtocol {
    // `ACP` also defines `SessionSummary`; keep local usages pinned to ACPClient.
    typealias SessionSummary = ACPClientSessionSummary

    // MARK: - Server Configuration

    let id: UUID
    @Published var name: String
    @Published var scheme: String
    @Published var host: String
    @Published var token: String
    @Published var cfAccessClientId: String
    @Published var cfAccessClientSecret: String
    @Published var workingDirectory: String

    var endpointURLString: String {
        "\(scheme)://\(host)"
    }

    // MARK: - Connection State

    /// Connection state delegated to connectionManager.
    var connectionState: ACPConnectionState { connectionManager.connectionState }
    /// Whether a connection attempt is in progress.
    var isConnecting: Bool { connectionManager.isConnecting }
    /// Whether network is available.
    var isNetworkAvailable: Bool { connectionManager.isNetworkAvailable }
    /// Last successful connection timestamp.
    var lastConnectedAt: Date? { connectionManager.lastConnectedAt }
    /// Whether initialize has completed for the current connection.
    var isInitialized: Bool { connectionManager.isInitialized }

    // MARK: - Sessions

    /// Dictionary of session view models keyed by session ID (from Phase 1)
    private var sessionViewModels: [String: ACPSessionViewModel] = [:]
    private var sessionViewModelCancellables: [String: AnyCancellable] = [:]

    @Published var sessionList: [String] = []
    @Published var sessionSummaries: [SessionSummary] = []
    @Published var selectedSessionId: String?
    @Published var sessionId: String = ""

    /// Returns the SessionViewModel for the currently selected session.
    var currentSessionViewModel: ACPSessionViewModel? {
        guard let sessionId = selectedSessionId, !sessionId.isEmpty else { return nil }

        if sessionViewModels[sessionId] == nil {
            let viewModel = createSessionViewModel(for: sessionId)
            sessionViewModels[sessionId] = viewModel
            setupSessionViewModelObservation(for: sessionId, viewModel: viewModel)
        }

        return sessionViewModels[sessionId]
    }

    var isStreaming: Bool {
        currentSessionViewModel?.chatMessages.contains(where: { $0.isStreaming }) ?? false
    }

    /// True when the active session hasn't been materialized on the server yet.
    var isPendingSession: Bool {
        pendingLocalSessions.contains(sessionId)
    }

    // MARK: - Agent Info & Modes

    @Published private(set) var agentInfo: AgentProfile?
    @Published private(set) var availableModes: [AgentModeOption] = []
    @Published private(set) var initializationSummary: String = "Not initialized"
    
    /// The default mode ID from the initialize response, applied to new sessions.
    private(set) var defaultModeId: String?

    /// Update agent info after initialization. Called by AppViewModel to sync capabilities.
    func updateAgentInfo(_ info: AgentProfile) {
        self.agentInfo = info
        self.availableModes = info.modes
        
        // Propagate capability changes to all active session view models
        let supportsImages = info.capabilities.promptCapabilities.image
        for viewModel in sessionViewModels.values {
            viewModel.setSupportsImageAttachment(supportsImages)
        }
    }

    /// Update connected protocol after initialization. Called by AppViewModel.
    func updateConnectedProtocol(_ proto: ACPConnectedProtocol?) {
        self.connectedProtocol = proto
    }

    // MARK: - Private State

    /// Connection manager handles network monitoring, reconnection, and connection lifecycle.
    private let connectionManager: ACPClientManager
    /// Convenience accessor for the active service.
    private var service: ACPService? { connectionManager.service }

    /// Detected protocol for this server.
    private var connectedProtocol: ACPConnectedProtocol?

    /// Cache delegates and dependencies
    weak var cacheDelegate: ACPSessionCacheDelegate?
    weak var eventDelegate: ACPSessionEventDelegate?
    weak var storage: SessionStorage?
    private let getServiceClosure: () -> ACPService?
    private let appendClosure: (String) -> Void
    private let logWireClosure: (String, ACPWireMessage) -> Void

    /// Session-related caches
    private var sessionCache: String = ""
    private var sessionSummaryCache: [SessionSummary] = []
    private(set) var lastLoadedSession: String?
    private var pendingLocalSessions: Set<String> = []
    private var pendingLocalSessionCwds: [String: String] = [:]
    private var pendingLocalSessionNewCwds: [String: Bool] = [:]
    private var creatingSessionTasks: [String: Task<Void, Never>] = [:]
    // Note: Unlike AppViewModel which uses (serverId: UUID, sessionId: String)? tuple,
    // ServerViewModel only needs String? since it represents a single server.
    var pendingSessionLoad: String?

    /// Placeholder ID -> Resolved ID mapping (Phase 1 session isolation)
    private var resolvedSessionIds: [String: String] = [:]

    /// Connection-related state
    private var pendingRequests: [ACP.ID: String] = [:]
    private var pendingNewSessionCwd: String?
    private var pendingNewSessionPlaceholderId: String?
    private var pendingMultiCwdFetch: (remaining: Int, sessions: [SessionSummary])?

    // MARK: - Initialization

    init(
        id: UUID,
        name: String,
        scheme: String,
        host: String,
        token: String,
        cfAccessClientId: String = "",
        cfAccessClientSecret: String = "",
        workingDirectory: String = "/",
        connectionManager: ACPClientManager,
        getService: @escaping () -> ACPService?,
        append: @escaping (String) -> Void,
        logWire: @escaping (String, ACPWireMessage) -> Void,
        cacheDelegate: ACPSessionCacheDelegate? = nil,
        storage: SessionStorage? = nil
    ) {
        self.id = id
        self.name = name
        self.scheme = scheme
        self.host = host
        self.token = token
        self.cfAccessClientId = cfAccessClientId
        self.cfAccessClientSecret = cfAccessClientSecret
        self.workingDirectory = workingDirectory
        self.connectionManager = connectionManager
        self.getServiceClosure = getService
        self.appendClosure = append
        self.logWireClosure = logWire
        self.cacheDelegate = cacheDelegate
        self.eventDelegate = self  // ServerViewModel now implements ACPSessionEventDelegate
        self.storage = storage
    }

    // MARK: - Session ViewModel Management (from Phase 1)

    /// Creates a new SessionViewModel instance for the given session ID.
    private func createSessionViewModel(for sessionId: String) -> ACPSessionViewModel {
        let viewModel = ACPSessionViewModel(
            dependencies: .init(
                getService: getServiceClosure,
                append: appendClosure,
                logWire: logWireClosure
            )
        )

        // Set delegates
        viewModel.cacheDelegate = cacheDelegate
        viewModel.eventDelegate = eventDelegate

        // Set image attachment support based on agent capabilities
        let supportsImages = agentInfo?.capabilities.promptCapabilities.image ?? false
        viewModel.setSupportsImageAttachment(supportsImages)

        return viewModel
    }

    /// Sets up observation for a session view model to forward its changes.
    private func setupSessionViewModelObservation(for sessionId: String, viewModel: ACPSessionViewModel) {
        let cancellable = viewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sessionViewModelCancellables[sessionId] = cancellable
    }

    /// Migrates a session view model from placeholder ID to resolved ID.
    func migrateSessionViewModel(from placeholderId: String, to resolvedId: String) {
        guard placeholderId != resolvedId else { return }

        if let viewModel = sessionViewModels.removeValue(forKey: placeholderId) {
            sessionViewModels[resolvedId] = viewModel

            // Migrate cancellable
            if let cancellable = sessionViewModelCancellables.removeValue(forKey: placeholderId) {
                sessionViewModelCancellables[resolvedId] = cancellable
            }
        }
    }

    /// Removes a session view model and cleans up its observation.
    func removeSessionViewModel(for sessionId: String) {
        sessionViewModels.removeValue(forKey: sessionId)
        sessionViewModelCancellables.removeValue(forKey: sessionId)?.cancel()
    }

    /// Removes all session view models for this server.
    func removeAllSessionViewModels() {
        sessionViewModels.removeAll()
        for cancellable in sessionViewModelCancellables.values {
            cancellable.cancel()
        }
        sessionViewModelCancellables.removeAll()
    }

    // MARK: - Session Helper Methods

    /// Check if this server supports session/load capability.
    private func canLoadSession() -> Bool {
        // Default to true - try server load first (will fail gracefully if not supported)
        // We can't default to false because agentInfo might not be set yet on startup
        agentInfo?.capabilities.loadSession ?? true
    }

    /// Check if this server supports session/resume capability.
    private func canResumeSession() -> Bool {
        agentInfo?.capabilities.resumeSession ?? false
    }

    /// Check if there are cached messages for a session.
    func hasCachedMessages(sessionId: String) -> Bool {
        return cacheDelegate?.loadMessages(for: id, sessionId: sessionId)?.isEmpty == false
    }

    /// Resolve effective working directory for this server.
    private func effectiveWorkingDirectory(endpointURL: URL, configuredWorkingDirectory: String) -> String {
        configuredWorkingDirectory
    }

    /// Resolve effective working directory for this server.
    private func effectiveWorkingDirectory(_ configuredWorkingDirectory: String) -> String {
        guard let endpointURL = URL(string: endpointURLString) else { return configuredWorkingDirectory }
        return effectiveWorkingDirectory(endpointURL: endpointURL, configuredWorkingDirectory: configuredWorkingDirectory)
    }

    /// Redact working directory for storage (don't store review endpoint paths).
    private func redactedWorkingDirectoryForStorage(_ cwd: String?) -> String? {
        cwd
    }

    /// Sanitize working directory input.
    private func sanitizeWorkingDirectory(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/" : trimmed
    }

    /// Resolved working directory for this server.
    private var resolvedWorkingDirectory: String {
        let sanitized = sanitizeWorkingDirectory(workingDirectory)
        guard let endpointURL = URL(string: endpointURLString) else { return sanitized }
        return effectiveWorkingDirectory(endpointURL: endpointURL, configuredWorkingDirectory: sanitized)
    }

    /// Remember a working directory as recently used.
    /// Returns true if this is a new working directory that was just added.
    @discardableResult
    private func rememberUsedWorkingDirectory(_ cwd: String) -> Bool {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return storage?.addUsedWorkingDirectory(trimmed, forServerId: id) ?? false
    }

    /// Re-fetch sessions if a new working directory was added and the agent supports session listing.
    private func refetchSessionsIfNeeded(newCwdAdded: Bool) {
        guard newCwdAdded else { return }
        guard let agentInfo = agentInfo, agentInfo.capabilities.listSessions else { return }
        guard connectionState == .connected else { return }

        appendClosure("New working directory detected; re-fetching sessions from all directories")
        fetchSessionList(force: true)
    }

    /// Remember session in cache and storage.
    /// Returns true if a new working directory was added.
    @discardableResult
    private func rememberSession(_ sessionId: String, cwd: String? = nil) -> Bool {
        guard !sessionId.isEmpty else { return false }
        sessionCache = sessionId
        let configuredCwd = cwd ?? resolvedWorkingDirectory
        let sessionCwd = effectiveWorkingDirectory(configuredCwd)
        let storedCwd = redactedWorkingDirectoryForStorage(sessionCwd)
        let now = Date()

        // Track timestamp and title from existing session (if any)
        let existingSession = sessionSummaries.first(where: { $0.id == sessionId })
        let timestamp = existingSession?.updatedAt ?? now
        let title = existingSession?.title

        if let index = sessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            // Update existing session's CWD if we have a more specific one
            let existing = sessionSummaries[index]
            if cwd != nil && existing.cwd != storedCwd {
                sessionSummaries[index] = SessionSummary(
                    id: existing.id,
                    title: existing.title,
                    cwd: storedCwd,
                    updatedAt: existing.updatedAt
                )
                setSessionSummaries(sessionSummaries) // Trigger UI update
            }
        } else {
            // Insert at the beginning with current timestamp so newest sessions appear first
            sessionSummaries.insert(SessionSummary(id: sessionId, title: nil, cwd: storedCwd, updatedAt: now), at: 0)
            setSessionSummaries(sessionSummaries) // Trigger UI update
        }

        // Never persist local-only draft sessions.
        guard !pendingLocalSessions.contains(sessionId) else { return false }

        // Persist to Core Data - preserve existing timestamp if updating
        let sessionInfo = StoredSessionInfo(sessionId: sessionId, title: title, cwd: storedCwd, updatedAt: timestamp)
        storage?.saveSession(sessionInfo, forServerId: id)
        return rememberUsedWorkingDirectory(sessionCwd)
    }

    // MARK: - Session List Management

    /// Check if this server supports session/list capability.
    private func sessionListSupportFlag() -> Bool? {
        agentInfo?.capabilities.listSessions
    }

    /// Check if session list can be fetched.
    private func canFetchSessionList(force: Bool = false) -> Bool {
        // Default to true - try server first, fall back to cache if it fails
        // The response handler will gracefully handle failures
        sessionListSupportFlag() ?? true
    }

    /// Sort session summaries by timestamp.
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
            case let (lDate?, rDate?):
                return lDate > rDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.id < rhs.id
            }
        }
    }

    /// Set session summaries for this server.
    private func setSessionSummaries(_ summaries: [SessionSummary]) {
        let sorted = sortSessionSummaries(summaries)
        sessionSummaries = sorted
        sessionSummaryCache = sorted
    }

    /// Load cached sessions for this server.
    func loadCachedSessions() {
        if !sessionSummaryCache.isEmpty {
            sessionSummaries = sessionSummaryCache
        } else if let storage = storage {
            // Try to load from Core Data first (persistent cache)
            let storedSessions = storage.fetchSessions(forServerId: id)
            if !storedSessions.isEmpty {
                let summaries = storedSessions.map { $0.toSessionSummary() }
                sessionSummaries = summaries
                appendClosure("Loaded \(storedSessions.count) persisted session(s) from storage")
            } else if !sessionCache.isEmpty {
                // Only fall back to single sessionCache if storage is also empty
                sessionSummaries = [SessionSummary(id: sessionCache, title: nil)]
            } else {
                sessionSummaries = []
            }
        } else if !sessionCache.isEmpty {
            // No storage available, use sessionCache as last resort
            sessionSummaries = [SessionSummary(id: sessionCache, title: nil)]
        } else {
            sessionSummaries = []
        }
    }

    /// Persist sessions to storage.
    private func persistSessionsToStorage() {
        let sessions = sessionSummaries
        guard !sessions.isEmpty || sessionListSupportFlag() == true else { return }

        for session in sessions {
            let storedInfo = StoredSessionInfo(
                sessionId: session.id,
                title: session.title,
                cwd: session.cwd,
                updatedAt: session.updatedAt
            )
            storage?.saveSession(storedInfo, forServerId: id)
        }

        // For agents that support `session/list`, prune stale cache entries
        if sessionListSupportFlag() == true {
            let keep = Set(sessions.map(\.id))
            _ = storage?.pruneSessions(forServerId: id, keeping: keep)
        }
    }

    /// Update session timestamp.
    private func bumpSessionTimestamp(sessionId: String, cwd: String? = nil, timestamp: Date = Date()) {
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

        setSessionSummaries(sessionSummaries)

        // Only persist local timestamps for servers that lack session/list
        let touchLocalTimestamp = (sessionListSupportFlag() == false)
        storage?.updateSession(sessionId: sessionId, forServerId: id, title: nil, touchUpdatedAt: touchLocalTimestamp)
    }

    /// Update session title from first prompt.
    private func updateSessionTitleIfNeeded(with text: String) {
        guard !sessionId.isEmpty else { return }
        guard let index = sessionSummaries.firstIndex(where: { $0.id == sessionId }),
              sessionSummaries[index].title == nil else { return }

        let maxLength = 30
        var title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count > maxLength {
            title = String(title.prefix(maxLength)) + "…"
        }

        let existingSession = sessionSummaries[index]
        sessionSummaries[index] = SessionSummary(id: sessionId, title: title, cwd: existingSession.cwd, updatedAt: existingSession.updatedAt)
        setSessionSummaries(sessionSummaries)

        let touchLocalTimestamp = (sessionListSupportFlag() == false)
        storage?.updateSession(sessionId: sessionId, forServerId: id, title: title, touchUpdatedAt: touchLocalTimestamp)
    }

    /// Fail a pending turn with an error message.
    private func failPendingTurn(_ message: String) {
        currentSessionViewModel?.abandonStreamingMessage()
        currentSessionViewModel?.addSystemErrorMessage(message)
    }

    /// Format prompt error for display.
    private func formatPromptError(_ error: Error) -> String {
        if let serviceError = error as? ACPServiceError, let message = serviceError.rpcMessage {
            return message
        }
        return error.localizedDescription
    }

    /// Finalize pending session creation after session/new response.
    private func finalizePendingSessionCreation(response: ACP.AnyResponse, placeholderId: String, fallbackCwd: String) {
        // Guard against duplicate finalization
        let isPending = pendingLocalSessions.contains(placeholderId)
        guard isPending else {
            return
        }

        pendingLocalSessionCwds.removeValue(forKey: placeholderId)

        // Parse session/new response
        let parsed = ACPSessionResponseParser.parseSessionNew(
            result: response.resultValue,
            fallbackCwd: pendingNewSessionCwd ?? fallbackCwd
        )

        // Extract session ID from response
        let resolvedId: String
        if let serverSessionId = parsed?.sessionId, !serverSessionId.isEmpty {
            resolvedId = serverSessionId
        } else {
            // Fallback extraction
            let directSessionId = response.resultValue?.objectValue?["sessionId"]?.stringValue
                ?? response.resultValue?.objectValue?["session"]?.stringValue
                ?? response.resultValue?.objectValue?["id"]?.stringValue

            if let directId = directSessionId, !directId.isEmpty {
                resolvedId = directId
            } else {
                resolvedId = placeholderId
            }
        }

        let resolvedCwd = parsed?.cwd ?? fallbackCwd
        let modesInfo = parsed?.modes

        // Check if this session introduced a new working directory before removing it from pending
        let newCwdAdded = pendingLocalSessionNewCwds[placeholderId] ?? false

        pendingLocalSessions.remove(placeholderId)
        pendingNewSessionCwd = nil
        pendingNewSessionPlaceholderId = nil

        // Record placeholder → resolved ID mapping
        if resolvedId != placeholderId {
            if resolvedSessionIds[placeholderId] == nil {
                resolvedSessionIds[placeholderId] = resolvedId
            }
        }

        // Migrate caches if ID changed
        if resolvedId != placeholderId {
            cacheDelegate?.migrateCache(serverId: id, from: placeholderId, to: resolvedId)
        }

        setActiveSession(resolvedId, cwd: resolvedCwd, modes: modesInfo)

        if resolvedId != placeholderId {
            removePlaceholderSession(placeholderId, replacedBy: resolvedId)
        }

        // Trigger session refetch if a new working directory was added during creation
        refetchSessionsIfNeeded(newCwdAdded: newCwdAdded)
    }

    /// Remove placeholder session after resolution.
    private func removePlaceholderSession(_ placeholderId: String, replacedBy resolvedId: String?) {
        if let resolvedId, resolvedId != placeholderId {
            // Delete placeholder session from storage if it exists (edge case protection)
            storage?.deleteSession(sessionId: placeholderId, forServerId: id)
        }

        pendingLocalSessions.remove(placeholderId)
        pendingLocalSessionCwds.removeValue(forKey: placeholderId)
        pendingLocalSessionNewCwds.removeValue(forKey: placeholderId)

        if sessionCache == placeholderId {
            sessionCache = resolvedId ?? ""
        }
        if pendingSessionLoad == placeholderId {
            pendingSessionLoad = nil
        }

        sessionSummaries.removeAll { $0.id == placeholderId }
        setSessionSummaries(sessionSummaries)

        removeSessionViewModel(for: placeholderId)
    }

    // MARK: - Connection Management

    // TODO: Move connection methods from AppViewModel
    // - connect()
    // - disconnect()
    // - initializeAndWait()
    // - Message handling

    // MARK: - Session Management

    /// Set the active session and load its state.
    func setActiveSession(_ id: String, cwd: String? = nil, modes: ACPModesInfo? = nil) {
        guard !id.isEmpty else { return }
        let isNew = sessionId != id
        sessionId = id
        selectedSessionId = id

        // Load chat state through currentSessionViewModel
        if isNew {
            currentSessionViewModel?.loadChatState(
                serverId: self.id,
                sessionId: id,
                canLoadFromStorage: canLoadSession() == false
            )
        } else {
            // Just update context for existing session
            currentSessionViewModel?.setSessionContext(serverId: self.id, sessionId: id)
        }

        // Restore or update mode state
        if let modes = modes {
            availableModes = modes.availableModes
            defaultModeId = modes.currentModeId
            currentSessionViewModel?.setCurrentModeId(modes.currentModeId)
            currentSessionViewModel?.cacheCurrentMode(serverId: self.id, sessionId: id)
        } else if let cachedMode = currentSessionViewModel?.cachedMode(for: self.id, sessionId: id) {
            currentSessionViewModel?.setCurrentModeId(cachedMode)
        } else if let defaultMode = defaultModeId {
            // Apply the default mode from initialize response for new sessions
            currentSessionViewModel?.setCurrentModeId(defaultMode)
        }
        // Note: defaultModeId is set from initialize response and applied to new sessions

        currentSessionViewModel?.restoreAvailableCommands(for: self.id, sessionId: id, isNew: isNew)

        if pendingLocalSessions.contains(id) {
            pendingSessionLoad = nil
        } else if canLoadSession() && connectionState != .connected {
            pendingSessionLoad = id
        } else {
            pendingSessionLoad = nil
        }

        let newCwdAdded = rememberSession(id, cwd: cwd)
        currentSessionViewModel?.saveChatState()
        if isNew {
            appendClosure("Session ID: \(id)")
        }
        refetchSessionsIfNeeded(newCwdAdded: newCwdAdded)
    }

    /// Set the default mode ID from initialize response, to be applied to new sessions.
    func setDefaultModeId(_ modeId: String?) {
        defaultModeId = modeId
    }

    /// Load a session from the server using session/load.
    func sendLoadSession(_ sessionIdToLoad: String, cwd: String? = nil) {
        guard let service = getServiceClosure() else {
            appendClosure("Not connected")
            return
        }
        guard canLoadSession() else {
            appendClosure("Agent does not support session/load; showing cached messages only")
            pendingSessionLoad = nil
            return
        }

        // Clear messages before loading from server - the server will replay history.
        currentSessionViewModel?.setChatMessages([])
        currentSessionViewModel?.resetStreamingState()

        // Determine the correct CWD for this session
        let sessionCwd: String
        if let cwd, !cwd.isEmpty {
            sessionCwd = cwd
        } else if let summary = sessionSummaries.first(where: { $0.id == sessionIdToLoad }),
                  let storedCwd = summary.cwd {
            sessionCwd = storedCwd
        } else {
            sessionCwd = resolvedWorkingDirectory
        }
        let effectiveCwd = effectiveWorkingDirectory(sessionCwd)

        let payload = ACPSessionLoadPayload(
            sessionId: sessionIdToLoad,
            workingDirectory: effectiveCwd
        )

        Task { @MainActor in
            do {
                _ = try await service.loadSession(payload)
            } catch {
                appendClosure("Failed to load session: \(error)")
            }
        }
        pendingSessionLoad = nil
    }

    /// Open a session - if connected, use session/load to restore it from the server.
    func openSession(_ id: String) {
        // IMPORTANT: If this ID is a placeholder that has been resolved, use the resolved ID.
        // This prevents the session ID from bouncing back to the placeholder when SwiftUI
        // re-renders the view with stale navigation state.
        let resolvedId = resolvedSessionIds[id] ?? id

        if connectedProtocol == .codexAppServer {
            setActiveSession(resolvedId)
            return
        }
        // If we have cached messages for this session, just use them.
        // Only send session/load if cache is empty (e.g., fresh app launch).
        let hasCachedMessages = hasCachedMessages(sessionId: resolvedId)

        // Also check if we have locally stored messages (for agents without session/load)
        let hasStoredMessages = !(storage?.fetchMessages(forSessionId: resolvedId, serverId: self.id).isEmpty ?? true)

        setActiveSession(resolvedId)

        // Draft local sessions haven't been created on the server yet.
        // Note: Check both original id and resolvedId since the placeholder may not yet be removed
        if pendingLocalSessions.contains(id) || pendingLocalSessions.contains(resolvedId) {
            pendingSessionLoad = nil
            lastLoadedSession = resolvedId
            return
        }

        // If `session/resume` is supported, we reattach on-demand as part of prompt preflight.

        if hasCachedMessages || hasStoredMessages {
            // Use cache or stored messages, no need to load from server
            lastLoadedSession = resolvedId
            pendingSessionLoad = nil
        } else if canLoadSession() {
            // Need to load from server
            if connectionState == .connected, isInitialized {
                sendLoadSession(resolvedId)
            } else {
                // Not connected or not initialized yet - queue for later
                pendingSessionLoad = resolvedId
                // Trigger connection and initialization if needed
                // Note: connectInitializeAndFetchSessions will be moved in a later step
                if connectionState != .connected {
                    // TODO: Call connectInitializeAndFetchSessions() when it's moved
                }
            }
        } else {
            pendingSessionLoad = nil
        }
    }

    /// Create a new session.
    func sendNewSession(workingDirectory: String? = nil) {
        let sanitizedCwd = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? sanitizeWorkingDirectory(workingDirectory!)
            : nil

        if connectedProtocol == .codexAppServer {
            appendClosure("Codex threads are handled by CodexServerViewModel")
            return
        }

        let pendingId = UUID().uuidString
        if let sanitizedCwd {
            pendingLocalSessionCwds[pendingId] = sanitizedCwd
            let newCwdAdded = rememberUsedWorkingDirectory(sanitizedCwd)
            pendingLocalSessionNewCwds[pendingId] = newCwdAdded
        }

        pendingLocalSessions.insert(pendingId)
        setActiveSession(pendingId, cwd: sanitizedCwd)

        // Try to create session immediately if connected and initialized
        if connectionState == .connected,
           let service = getServiceClosure(),
           isInitialized {
            let configuredCwd = sanitizedCwd ?? resolvedWorkingDirectory
            let creationCwd = effectiveWorkingDirectory(configuredCwd)
            pendingNewSessionCwd = creationCwd
            pendingNewSessionPlaceholderId = pendingId
            let newCwdAdded = rememberUsedWorkingDirectory(creationCwd)
            // Update the flag - use OR to preserve any previous true value
            pendingLocalSessionNewCwds[pendingId] = (pendingLocalSessionNewCwds[pendingId] == true) || newCwdAdded

            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                let payload = ACPSessionCreatePayload(
                    workingDirectory: creationCwd,
                    mcpServers: []
                )

                do {
                    let response = try await service.createSession(payload)
                    self.finalizePendingSessionCreation(
                        response: response,
                        placeholderId: pendingId,
                        fallbackCwd: creationCwd
                    )
                    self.appendClosure("Session created with metadata")
                } catch {
                    self.failPendingSessionCreation(
                        placeholderId: pendingId,
                        errorMessage: error.localizedDescription
                    )
                }
                self.creatingSessionTasks.removeValue(forKey: pendingId)
            }
            creatingSessionTasks[pendingId] = task
            appendClosure("Creating new session...")
        } else {
            appendClosure("Prepared new session (will be created on first send)")
        }
    }

    /// Delete a session.
    func deleteSession(_ sessionId: String) {
        // Cancel any in-flight session creation task
        creatingSessionTasks[sessionId]?.cancel()
        creatingSessionTasks.removeValue(forKey: sessionId)
        pendingLocalSessions.remove(sessionId)
        pendingLocalSessionCwds.removeValue(forKey: sessionId)
        pendingLocalSessionNewCwds.removeValue(forKey: sessionId)
        resolvedSessionIds.removeValue(forKey: sessionId)
        sessionSummaries.removeAll { $0.id == sessionId }
        setSessionSummaries(sessionSummaries)

        cacheDelegate?.clearCache(for: id, sessionId: sessionId)
        currentSessionViewModel?.removeCommands(for: id, sessionId: sessionId)

        if sessionCache == sessionId {
            sessionCache = ""
        }

        if self.sessionId == sessionId {
            self.sessionId = ""
            self.selectedSessionId = nil
            currentSessionViewModel?.resetChatState()
        }

        removeSessionViewModel(for: sessionId)
        storage?.deleteSession(sessionId: sessionId, forServerId: id)
    }

    /// Archive a session. ACP protocol does not support archive — this is a no-op.
    func archiveSession(_ sessionId: String) {
        // ACP protocol has no archive operation; use deleteSession for local removal.
    }

    /// Abort a pending session creation and clean up placeholder UI state.
    private func failPendingSessionCreation(placeholderId: String, errorMessage: String) {
        guard pendingLocalSessions.contains(placeholderId) else { return }

        // Surface the error in the chat area if the placeholder is currently selected.
        if selectedSessionId == placeholderId {
            currentSessionViewModel?.addSystemErrorMessage("Session creation failed: \(errorMessage)")
        }

        appendClosure("Failed to create session: \(errorMessage)")

        // Reset in-flight creation bookkeeping so retries start clean.
        creatingSessionTasks[placeholderId]?.cancel()
        creatingSessionTasks.removeValue(forKey: placeholderId)
        pendingNewSessionCwd = nil
        pendingNewSessionPlaceholderId = nil

        // Remove the placeholder session and any cached state.
        removePlaceholderSession(placeholderId, replacedBy: nil)
    }

    /// Fetch session list from server.
    func fetchSessionList(force: Bool = false) {
        guard canFetchSessionList(force: force) else {
            loadCachedSessions()
            return
        }

        if connectionState == .connected, let service = getServiceClosure() {
            // Always fetch from all working directories to get complete session list
            sendSessionListForAllWorkingDirectories(service: service)
        } else {
            loadCachedSessions()
        }
    }

    /// Send session/list request.
    private func sendSessionList(service: ACPService) {
        Task { @MainActor in
            do {
                let payload = ACPSessionListPayload(workingDirectory: effectiveWorkingDirectory(resolvedWorkingDirectory))
                _ = try await service.listSessions(payload)
            } catch {
                appendClosure("Failed to fetch sessions: \(error)")
            }
        }
    }

    /// Send session/list for all working directories.
    private func sendSessionListForAllWorkingDirectories(service: ACPService) {
        // Guard against duplicate fetches
        guard pendingMultiCwdFetch == nil else { return }

        guard let storage = storage else {
            sendSessionList(service: service)
            return
        }

        // Normalize and apply review overrides before issuing requests to avoid using "/" on review hosts.
        let effectiveCwds = Array(Set(storage.fetchUsedWorkingDirectories(forServerId: id).map { cwd in
            let sanitized = sanitizeWorkingDirectory(cwd)
            return effectiveWorkingDirectory(sanitized)
        }))

        guard !effectiveCwds.isEmpty else {
            sendSessionList(service: service)
            return
        }

        appendClosure("Fetching sessions for \(effectiveCwds.count) working director\(effectiveCwds.count == 1 ? "y" : "ies")...")
        pendingMultiCwdFetch = (remaining: effectiveCwds.count, sessions: [])

        for cwd in effectiveCwds {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let payload = ACPSessionListPayload(workingDirectory: cwd)
                do {
                    _ = try await service.listSessions(payload)
                } catch {
                    self.appendClosure("Failed to fetch sessions for \(cwd): \(error)")
                    // Decrement counter on error so we don't block forever
                    self.decrementMultiCwdFetch()
                }
            }
        }
    }

    /// Handle session/list response in multi-CWD fetch mode.
    func handleSessionListResult(_ sessions: [SessionSummary]) {
        guard var pending = pendingMultiCwdFetch else {
            // Not in multi-CWD mode, update directly
            // Only update if server supports session/list, otherwise keep cached sessions
            if sessionListSupportFlag() == true {
                setSessionSummaries(sessions)
                persistSessionsToStorage()
                appendClosure("Fetched \(sessions.count) session\(sessions.count == 1 ? "" : "s")")
            } else {
                // Server doesn't support list - this response shouldn't have happened
                // Keep existing cached sessions and ignore this response
                appendClosure("Ignoring unexpected session/list response (server doesn't support list)")
            }
            return
        }

        // Accumulate sessions
        pending.sessions.append(contentsOf: sessions)
        pending.remaining -= 1

        if pending.remaining <= 0 {
            // All requests completed, finalize
            pendingMultiCwdFetch = nil
            // Only update if server supports session/list
            if sessionListSupportFlag() == true {
                setSessionSummaries(pending.sessions)
                persistSessionsToStorage()
                appendClosure("Fetched \(sessionSummaries.count) unique session\(sessionSummaries.count == 1 ? "" : "s") across working directories")
            } else {
                // Server doesn't support list - keep existing cached sessions
                appendClosure("Ignoring multi-CWD fetch results (server doesn't support list)")
            }
        } else {
            // More requests pending
            pendingMultiCwdFetch = pending
        }
    }

    /// Decrement multi-CWD fetch counter (called on error).
    private func decrementMultiCwdFetch() {
        guard var pending = pendingMultiCwdFetch else { return }

        pending.remaining -= 1

        if pending.remaining <= 0 {
            // All requests completed (some failed), finalize with what we have
            pendingMultiCwdFetch = nil

            // Only update if server supports session/list, otherwise keep cached sessions
            if sessionListSupportFlag() == true {
                setSessionSummaries(pending.sessions)
                persistSessionsToStorage()
                if pending.sessions.isEmpty {
                    appendClosure("Failed to fetch sessions from all working directories")
                } else {
                    appendClosure("Fetched \(sessionSummaries.count) sessions (some directories failed)")
                }
            } else {
                // Server doesn't support list - keep existing cached sessions
                appendClosure("Ignoring multi-CWD fetch errors (server doesn't support list)")
            }
        } else {
            pendingMultiCwdFetch = pending
        }
    }

    /// Send a prompt to the current session.
    /// - Parameters:
    ///   - promptText: The text of the prompt
    ///   - images: Attached images
    ///   - commandName: Optional command name (e.g., "edit")
    func sendPrompt(promptText: String, images: [ImageAttachment], commandName: String? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let service = getServiceClosure() else {
                appendClosure("Not connected")
                return
            }
            guard connectionState == .connected else {
                appendClosure("Not connected")
                return
            }
            guard !sessionId.isEmpty else {
                appendClosure("Create or load a session first")
                return
            }

            // End any prior streaming assistant message
            currentSessionViewModel?.abandonStreamingMessage()

            var prompt = promptText
            if let commandName {
                let prefix = "/\(commandName)"
                let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedPrompt.hasPrefix(prefix) {
                    // Already includes the command prefix
                } else if trimmedPrompt.isEmpty {
                    prompt = prefix
                } else {
                    prompt = "\(prefix) \(prompt)"
                }
            }

            // Don't create an empty turn
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, images.isEmpty {
                appendClosure("Cannot send empty prompt")
                failPendingTurn("Cannot send empty prompt")
                return
            }

            // Show the user's message immediately
            let chatImages = images.map { ChatImageData(from: $0) }
            currentSessionViewModel?.addUserMessage(content: prompt, images: chatImages)
            currentSessionViewModel?.startNewStreamingResponse()

            if !isInitialized {
                appendClosure("Initialize needed but not yet moved to ServerViewModel")
                failPendingTurn("Initialize needed")
                return
            }

            if connectedProtocol == .codexAppServer {
                appendClosure("Codex prompts are handled by CodexServerViewModel")
                return
            }

            // Handle pending local session creation
            if pendingLocalSessions.contains(sessionId) {
                let placeholderId = sessionId

                // Await in-flight session creation task if any
                if let creationTask = creatingSessionTasks[placeholderId] {
                    await creationTask.value

                    if let resolvedId = resolvedSessionIds[placeholderId] {
                        if sessionId != resolvedId {
                            setActiveSession(resolvedId)
                        }
                        resolvedSessionIds.removeValue(forKey: placeholderId)
                    }
                }

                // If still pending, create it now
                if pendingLocalSessions.contains(sessionId) {
                    let configuredCwd = pendingLocalSessionCwds[placeholderId] ?? resolvedWorkingDirectory
                    let creationCwd = effectiveWorkingDirectory(configuredCwd)
                    pendingNewSessionCwd = creationCwd
                    pendingNewSessionPlaceholderId = placeholderId
                    let newCwdAdded = rememberUsedWorkingDirectory(creationCwd)
                    // Update the flag - use OR to preserve any previous true value
                    pendingLocalSessionNewCwds[placeholderId] = (pendingLocalSessionNewCwds[placeholderId] == true) || newCwdAdded

                    let payload = ACPSessionCreatePayload(
                        workingDirectory: creationCwd,
                        mcpServers: []
                    )

                    do {
                        let response = try await service.createSession(payload)
                        finalizePendingSessionCreation(
                            response: response,
                            placeholderId: placeholderId,
                            fallbackCwd: creationCwd
                        )

                        if let resolvedId = resolvedSessionIds[placeholderId] {
                            if sessionId != resolvedId {
                                setActiveSession(resolvedId)
                            }
                            resolvedSessionIds.removeValue(forKey: placeholderId)
                        }
                    } catch {
                        failPendingSessionCreation(
                            placeholderId: placeholderId,
                            errorMessage: error.localizedDescription
                        )
                        failPendingTurn("Failed to create session: \(error.localizedDescription)")
                        return
                    }

                    guard !sessionId.isEmpty else {
                        appendClosure("Create or load a session first")
                        failPendingTurn("Create or load a session first")
                        return
                    }
                }
            }

            guard !sessionId.isEmpty else {
                appendClosure("Create or load a session first")
                failPendingTurn("Create or load a session first")
                return
            }

            // Handle session resume if needed
            if canLoadSession() == false,
               canResumeSession(),
               !pendingLocalSessions.contains(sessionId),
               !connectionManager.isSessionMaterialized(sessionId),
               !connectionManager.isResumingSession(sessionId) {
                let sessionToResume = sessionId
                let configuredCwd = sessionSummaries.first(where: { $0.id == sessionToResume })?.cwd ?? resolvedWorkingDirectory
                let resumeCwd = effectiveWorkingDirectory(configuredCwd)

                connectionManager.setResumingSession(sessionToResume, isResuming: true)
                defer { connectionManager.setResumingSession(sessionToResume, isResuming: false) }

                do {
                    let payload = ACPSessionResumePayload(
                        sessionId: sessionToResume,
                        workingDirectory: resumeCwd,
                        mcpServers: []
                    )
                    _ = try await service.resumeSession(payload)
                    connectionManager.markSessionMaterialized(sessionToResume)
                } catch {
                    if case ACPServiceError.rpc(_, let rpcError) = error, rpcError.code == -32601 {
                        if var info = agentInfo {
                            info.capabilities.resumeSession = false
                            agentInfo = info
                        }
                        appendClosure("session/resume disabled for this agent (Method not found)")
                    } else {
                        appendClosure("Failed to resume session: \(error)")
                    }
                    failPendingTurn("Failed to resume session: \(error.localizedDescription)")
                    return
                }

                guard !sessionId.isEmpty else {
                    appendClosure("Create or load a session first")
                    failPendingTurn("Create or load a session first")
                    return
                }
            }

            bumpSessionTimestamp(sessionId: sessionId)
            updateSessionTitleIfNeeded(with: prompt)

            // Log image attachment info
            if !images.isEmpty {
                appendClosure("Sending \(images.count) image(s): \(images.map { "\($0.mimeType) (\($0.sizeDescription))" }.joined(separator: ", "))")
            }

            // Build prompt content
            let imageInputs = images.map { ACPImageInput(mimeType: $0.mimeType, base64Data: $0.base64Data) }
            let promptCapabilities = agentInfo?.capabilities.promptCapabilities
            let buildResult = ACPPromptBuilder.build(
                text: prompt,
                images: imageInputs,
                capabilities: promptCapabilities
            )

            // Log warnings
            for warning in buildResult.warnings {
                appendClosure("Warning: \(warning)")
            }

            appendClosure("Prompt content blocks: \(buildResult.debugSummary)")

            // Validate prompt
            if let validationError = ACPPromptBuilder.validate(buildResult) {
                appendClosure(validationError)
                failPendingTurn(validationError)
                return
            }

            guard let payload = buildResult.makePayload(sessionId: sessionId) else {
                appendClosure("Cannot send empty prompt")
                failPendingTurn("Cannot send empty prompt")
                return
            }

            do {
                _ = try await service.sendPrompt(payload)
            } catch {
                appendClosure("Failed to send prompt: \(error)")
                let errorMessage = formatPromptError(error)
                failPendingTurn(errorMessage)
            }
        }
    }
}

// MARK: - ACPSessionEventDelegate

extension ServerViewModel: ACPSessionEventDelegate {
    func sessionModeDidChange(_ modeId: String, serverId: UUID, sessionId: String) {
        // Log mode change for user visibility
        appendClosure("Mode changed to: \(modeId)")
    }

    func sessionDidReceiveStopReason(_ reason: String, serverId: UUID, sessionId: String) {
        // Log stop reason for user visibility
        appendClosure("Prompt stopReason: \(reason)")
    }

    func sessionLoadDidComplete(serverId: UUID, sessionId: String) {
        // Track that this session was successfully loaded
        lastLoadedSession = sessionId
    }
}