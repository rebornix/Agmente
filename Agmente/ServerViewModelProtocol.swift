import Foundation
import ACPClient

/// Protocol defining the common interface for server view models.
/// Allows AppViewModel to work with both ACP and Codex server types polymorphically.
@MainActor
protocol ServerViewModelProtocol: ObservableObject, Identifiable where ID == UUID {
    // MARK: - Server Configuration

    var id: UUID { get }
    var name: String { get set }
    var scheme: String { get set }
    var host: String { get set }
    var token: String { get set }
    var cfAccessClientId: String { get set }
    var cfAccessClientSecret: String { get set }
    var workingDirectory: String { get set }
    var endpointURLString: String { get }

    // MARK: - Connection State

    var connectionState: ACPConnectionState { get }
    var isConnecting: Bool { get }
    var isNetworkAvailable: Bool { get }
    var lastConnectedAt: Date? { get }
    var isInitialized: Bool { get }

    // MARK: - Sessions

    var sessionId: String { get set }
    var selectedSessionId: String? { get set }
    var sessionSummaries: [SessionSummary] { get set }
    var currentSessionViewModel: ACPSessionViewModel? { get }
    var isStreaming: Bool { get }
    var isPendingSession: Bool { get }

    // MARK: - Agent Info

    var agentInfo: AgentProfile? { get }
    var availableModes: [AgentModeOption] { get }
    var initializationSummary: String { get }

    // MARK: - Session Management

    /// Fetch the list of sessions from the server.
    func fetchSessionList(force: Bool)

    /// Create a new session with optional working directory.
    func sendNewSession(workingDirectory: String?)

    /// Open an existing session.
    func openSession(_ id: String)

    /// Delete a session.
    func deleteSession(_ sessionId: String)

    /// Set the active session.
    func setActiveSession(_ id: String, cwd: String?, modes: ACPModesInfo?)

    /// Send a prompt to the current session.
    func sendPrompt(promptText: String, images: [ImageAttachment], commandName: String?)

    // MARK: - Agent Info Updates

    /// Update agent info after initialization.
    func updateAgentInfo(_ info: AgentProfile)

    /// Update connected protocol after initialization.
    func updateConnectedProtocol(_ proto: ACPConnectedProtocol?)

    /// Set the default mode ID from initialize response.
    func setDefaultModeId(_ modeId: String?)

    // MARK: - Cache Operations

    /// Load cached sessions.
    func loadCachedSessions()

    /// Check if there are cached messages for a session.
    func hasCachedMessages(sessionId: String) -> Bool

    // MARK: - Session Load

    /// Send session/load request (ACP-specific, no-op for Codex).
    func sendLoadSession(_ sessionId: String, cwd: String?)

    /// Handle session list result from server.
    func handleSessionListResult(_ sessions: [SessionSummary])

    // MARK: - Session ViewModel Management

    /// Migrate session view model from placeholder to resolved ID.
    func migrateSessionViewModel(from placeholderId: String, to resolvedId: String)

    /// Remove a session view model.
    func removeSessionViewModel(for sessionId: String)

    /// Remove all session view models.
    func removeAllSessionViewModels()

    // MARK: - Delegates & Storage

    var cacheDelegate: ACPSessionCacheDelegate? { get set }
    var eventDelegate: ACPSessionEventDelegate? { get set }
    var storage: SessionStorage? { get set }
    var lastLoadedSession: String? { get }
    var pendingSessionLoad: String? { get set }
}

/// Default implementations for optional methods.
extension ServerViewModelProtocol {
    func fetchSessionList(force: Bool = false) {
        fetchSessionList(force: force)
    }

    func sendNewSession(workingDirectory: String? = nil) {
        sendNewSession(workingDirectory: workingDirectory)
    }

    func sendPrompt(promptText: String, images: [ImageAttachment] = [], commandName: String? = nil) {
        sendPrompt(promptText: promptText, images: images, commandName: commandName)
    }

    func setActiveSession(_ id: String, cwd: String? = nil, modes: ACPModesInfo? = nil) {
        setActiveSession(id, cwd: cwd, modes: modes)
    }

    func sendLoadSession(_ sessionId: String, cwd: String? = nil) {
        sendLoadSession(sessionId, cwd: cwd)
    }
}