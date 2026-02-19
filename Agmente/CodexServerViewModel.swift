import Foundation
import SwiftUI
import Combine
import ACPClient
import struct AppServerClient.AppServerModel
import struct AppServerClient.AppServerReasoningEffortOption
import struct AppServerClient.AppServerSkill
import enum AppServerClient.AppServerSkillScope

/// Codex app-server specific ServerViewModel implementation.
/// Handles thread/turn semantics and Codex-specific protocol differences.
@MainActor
final class CodexServerViewModel: ObservableObject, Identifiable, ServerViewModelProtocol {

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

    var connectionState: ACPConnectionState { connectionManager.connectionState }
    var isConnecting: Bool { connectionManager.isConnecting }
    var isNetworkAvailable: Bool { connectionManager.isNetworkAvailable }
    var lastConnectedAt: Date? { connectionManager.lastConnectedAt }
    var isInitialized: Bool { connectionManager.isInitialized }

    // MARK: - Sessions (Codex calls them "threads")

    private var sessionViewModels: [String: ACPSessionViewModel] = [:]
    private var sessionViewModelCancellables: [String: AnyCancellable] = [:]

    @Published var sessionSummaries: [SessionSummary] = []
    @Published var selectedSessionId: String?
    @Published var sessionId: String = ""

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
        return hasStreamingAssistantMessage(in: selectedSessionId)
    }

    var isPendingSession: Bool {
        // Codex threads are created immediately, no pending state
        false
    }

    // MARK: - Agent Info (Protocol Conformance)
    // Note: App-server protocol doesn't provide agent info/modes. These exist for protocol conformance only.

    @Published private(set) var agentInfo: AgentProfile?
    // App-server protocol has no agent/mode/list - always empty
    var availableModes: [AgentModeOption] { [] }
    @Published private(set) var initializationSummary: String = "Not initialized"

    private(set) var defaultModeId: String?

    // MARK: - Model Selection (Codex-specific)

    @Published private(set) var availableModels: [AppServerModel] = []
    @Published var selectedModelId: String?
    @Published var selectedEffort: String?

    var selectedModel: AppServerModel? {
        guard let id = selectedModelId else {
            return availableModels.first(where: { $0.isDefault })
        }
        return availableModels.first(where: { $0.id == id })
    }

    var defaultModel: AppServerModel? {
        availableModels.first(where: { $0.isDefault })
    }

    // MARK: - Skills Selection (Codex-specific)

    @Published private(set) var availableSkills: [AppServerSkill] = []
    @Published var enabledSkillNames: Set<String> = []

    // MARK: - Permissions Selection (Codex-specific)

    enum PermissionPreset: String, CaseIterable, Identifiable {
        case defaultPermissions
        case fullAccess

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .defaultPermissions:
                return "Default permissions"
            case .fullAccess:
                return "Full access"
            }
        }

        var turnApprovalPolicy: String {
            switch self {
            case .defaultPermissions:
                return "on-request"
            case .fullAccess:
                return "never"
            }
        }

        var turnSandboxPolicy: JSONValue {
            switch self {
            case .defaultPermissions:
                return .object(["type": .string("workspaceWrite")])
            case .fullAccess:
                return .object(["type": .string("dangerFullAccess")])
            }
        }
    }

    @Published var permissionPreset: PermissionPreset = .defaultPermissions

    // MARK: - Plan Mode (Codex-specific)

    @Published var isPlanModeEnabled: Bool = false

    // MARK: - Private State

    private let connectionManager: ACPClientManager
    private var service: ACPService? { connectionManager.service }

    private var sessionSummaryCache: [SessionSummary] = []
    private var sessionMessageKeys: [String: [UUID: String]] = [:]

    private var activeThreadId: String?
    private var activeTurnId: String?
    private var lastResumeAtByThreadId: [String: Date] = [:]
    private var postResumeRefreshTask: Task<Void, Never>?
    private var openSessionTask: Task<Void, Never>?
    private var openSessionRequestToken: UInt64 = 0
    private var needsInitializedAck: Bool = false
    private var reasoningCache: [String: String] = [:]
    private static let proposedPlanRegex = try? NSRegularExpression(
        pattern: "<proposed_plan>([\\s\\S]*?)</proposed_plan>",
        options: [.caseInsensitive]
    )

    func markInitializedAckNeeded() {
        needsInitializedAck = true
    }

    weak var cacheDelegate: ACPSessionCacheDelegate?
    weak var eventDelegate: ACPSessionEventDelegate?
    weak var storage: SessionStorage?
    private let getServiceClosure: () -> ACPService?
    private let appendClosure: (String) -> Void
    private let logWireClosure: (String, ACPWireMessage) -> Void
    private let sessionLogger: CodexSessionLogger?
    private let isSessionLoggingEnabled: () -> Bool

    private(set) var lastLoadedSession: String?
    var pendingSessionLoad: String?

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
        sessionLogger: CodexSessionLogger? = nil,
        isSessionLoggingEnabled: @escaping () -> Bool = { true },
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
        self.sessionLogger = sessionLogger
        self.isSessionLoggingEnabled = isSessionLoggingEnabled
        self.cacheDelegate = cacheDelegate
        self.eventDelegate = self
        self.storage = storage
    }

    deinit {
        openSessionTask?.cancel()
        let logger = sessionLogger
        Task { [logger] in
            await logger?.endSession()
        }
    }

    // MARK: - Session ViewModel Management

    private func createSessionViewModel(for sessionId: String) -> ACPSessionViewModel {
        let viewModel = ACPSessionViewModel(
            dependencies: .init(
                getService: getServiceClosure,
                append: appendClosure,
                logWire: logWireClosure
            )
        )

        viewModel.cacheDelegate = cacheDelegate
        viewModel.eventDelegate = eventDelegate

        let supportsImages = agentInfo?.capabilities.promptCapabilities.image ?? false
        viewModel.setSupportsImageAttachment(supportsImages)

        return viewModel
    }

    private func setupSessionViewModelObservation(for sessionId: String, viewModel: ACPSessionViewModel) {
        let cancellable = viewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sessionViewModelCancellables[sessionId] = cancellable
    }

    func migrateSessionViewModel(from placeholderId: String, to resolvedId: String) {
        guard placeholderId != resolvedId else { return }

        if let viewModel = sessionViewModels.removeValue(forKey: placeholderId) {
            sessionViewModels[resolvedId] = viewModel

            if let cancellable = sessionViewModelCancellables.removeValue(forKey: placeholderId) {
                sessionViewModelCancellables[resolvedId] = cancellable
            }
        }
    }

    func removeSessionViewModel(for sessionId: String) {
        sessionViewModels.removeValue(forKey: sessionId)
        sessionViewModelCancellables.removeValue(forKey: sessionId)?.cancel()
        sessionMessageKeys.removeValue(forKey: sessionId)
    }

    func removeAllSessionViewModels() {
        cancelOpenSessionTask()
        cancelPostResumeRefreshTask()
        sessionViewModels.removeAll()
        for cancellable in sessionViewModelCancellables.values {
            cancellable.cancel()
        }
        sessionViewModelCancellables.removeAll()
        sessionMessageKeys.removeAll()
        Task { await sessionLogger?.endSession() }
    }

    // MARK: - Codex Helpers

    private struct CodexThreadResumeResult: Equatable {
        struct Turn: Equatable {
            let id: String
            let status: String?
            let items: [Item]
        }

        enum Item: Equatable {
            case userMessage(id: String?, text: String)
            case agentMessage(id: String?, text: String)
            case plan(id: String?, text: String)
            case reasoning(id: String?, text: String)
            case commandExecution(id: String?, command: String?, output: String?)
            case fileChange(id: String?, path: String?, changeType: String?, diff: String?)
            case toolCall(id: String?, title: String, kind: String?, status: String?, output: String?)
            case unknown(type: String)
        }

        let id: String
        let preview: String?
        let cwd: String?
        let createdAt: Date?
        let activeTurnId: String?
        let turns: [Turn]
    }

    private func ensureInitializedAck() async {
        guard needsInitializedAck else { return }
        guard let service = getServiceClosure() else { return }
        let notification = JSONRPCMessage.notification(
            JSONRPCNotification(method: "notifications/initialized", params: nil)
        )
        do {
            try await service.sendMessage(notification)
            needsInitializedAck = false
        } catch {
            // Best-effort: keep flag set to retry on next call.
        }
    }

    // MARK: - Agent Info Updates (Protocol Conformance)
    // Note: App-server protocol doesn't provide agent info. These exist for protocol conformance only.

    func updateAgentInfo(_ info: AgentProfile) {
        // App-server protocol only provides userAgent string, not full AgentProfile.
        // This is a no-op for Codex servers.
        self.agentInfo = info
    }

    func updateConnectedProtocol(_ proto: ACPConnectedProtocol?) {
        // Codex server always uses Codex protocol - this is a no-op
    }

    func setDefaultModeId(_ modeId: String?) {
        // App-server protocol has no modes - this is a no-op
        defaultModeId = modeId
    }

    // MARK: - Model List

    func fetchModels() {
        guard connectionState == .connected, let service = getServiceClosure() else {
            appendClosure("Cannot fetch models: not connected")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let models = try await listModels()
                self.availableModels = models
                appendClosure("Fetched \(models.count) model(s)")

                // Set default model and effort if not already selected
                if selectedModelId == nil, let defaultModel = models.first(where: { $0.isDefault }) {
                    selectedModelId = defaultModel.id
                    selectedEffort = defaultModel.defaultReasoningEffort
                }
            } catch {
                appendClosure("Failed to fetch models: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Skills List

    func fetchSkills(sessionId: String? = nil, cwdOverride: String? = nil) {
        guard connectionState == .connected, let service = getServiceClosure() else {
            appendClosure("Cannot fetch skills: not connected")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Use explicit cwd when provided, otherwise resolve from session id.
                let resolvedSessionId = sessionId ?? self.sessionId
                let cwd = cwdOverride
                    ?? sessionSummaries.first(where: { $0.id == resolvedSessionId })?.cwd
                    ?? workingDirectory
                let cwds = cwd.isEmpty ? nil : [cwd]
                let skills = try await listSkills(cwds: cwds)
                self.availableSkills = skills
                appendClosure("Fetched \(skills.count) skill(s)")
            } catch {
                appendClosure("Failed to fetch skills: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Session Management

    func setActiveSession(_ id: String, cwd: String?, modes: ACPModesInfo?) {
        guard !id.isEmpty else { return }
        let isNew = sessionId != id
        if isNew {
            activeTurnId = nil
        }
        sessionId = id
        selectedSessionId = id
        activeThreadId = id
        reasoningCache.removeAll()
        if isSessionLoggingEnabled() {
            Task { await sessionLogger?.startSession(sessionId: id, endpoint: endpointURLString, cwd: cwd ?? workingDirectory) }
        }

        // For Codex, we DON'T load from Core Data storage.
        // Chat history comes from the server via thread/resume (called in openSession).
        // setActiveSession is called AFTER we've already populated messages from the server.
        currentSessionViewModel?.setSessionContext(serverId: self.id, sessionId: id)

        // Note: App-server protocol doesn't support modes, so modes param is always nil for Codex.
        // We still handle mode caching for potential future support.
        if let modes = modes {
            defaultModeId = modes.currentModeId
            currentSessionViewModel?.setCurrentModeId(modes.currentModeId)
            currentSessionViewModel?.cacheCurrentMode(serverId: self.id, sessionId: id)
        } else if let cachedMode = currentSessionViewModel?.cachedMode(for: self.id, sessionId: id) {
            currentSessionViewModel?.setCurrentModeId(cachedMode)
        } else if let defaultMode = defaultModeId {
            currentSessionViewModel?.setCurrentModeId(defaultMode)
        }

        currentSessionViewModel?.restoreAvailableCommands(for: self.id, sessionId: id, isNew: isNew)

        pendingSessionLoad = nil
        rememberSession(id, cwd: cwd)
        currentSessionViewModel?.saveChatState()

        if isNew {
            appendClosure("Thread ID: \(id)")
        }
    }

    func openSession(_ id: String) {
        let pendingCwd = sessionSummaries.first(where: { $0.id == id })?.cwd
        let requestToken = beginOpenSessionRequest(id, cwd: pendingCwd)
        // For Codex, we use thread/resume to fetch full history from server
        openSessionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if isCurrentOpenSessionRequest(requestToken, for: id) {
                    openSessionTask = nil
                }
            }

            guard isCurrentOpenSessionRequest(requestToken, for: id) else {
                trace("openSession skip stale-start thread=\(id)")
                return
            }

            cancelPostResumeRefreshTask()
            trace("openSession begin thread=\(id) selectedSession=\(selectedSessionId ?? "nil") activeThread=\(activeThreadId ?? "nil") activeTurn=\(activeTurnId ?? "nil") state=\(String(describing: connectionState))")
            guard let service = getServiceClosure() else {
                trace("openSession fallback: service=nil")
                appendClosure("Not connected - falling back to local cache")
                if isCurrentOpenSessionRequest(requestToken, for: id) {
                    pendingSessionLoad = nil
                }
                return
            }
            guard connectionState == .connected else {
                trace("openSession fallback: state=\(String(describing: connectionState))")
                appendClosure("Not connected - falling back to local cache")
                if isCurrentOpenSessionRequest(requestToken, for: id) {
                    pendingSessionLoad = nil
                }
                return
            }
            _ = service

            do {
                // Fetch models if not already loaded
                if availableModels.isEmpty {
                    fetchModels()
                }

                let existingMessages = sessionViewModels[id]?.chatMessages ?? []
                let hadStreamingBeforeResume = (id == sessionId && activeTurnId != nil)
                    || existingMessages.contains(where: { $0.isStreaming })
                trace(
                    "openSession pre-resume thread=\(id) existingMessages=\(existingMessages.count) existingToolCalls=\(countToolCallSegments(in: existingMessages)) hadStreaming=\(hadStreamingBeforeResume)"
                )

                var usedResumeBasedHydration = true
                var hydrationSource = "thread/resume"
                let result: CodexThreadResumeResult

                do {
                    if let attached = try await attachLoadedThreadAndRead(threadId: id) {
                        result = attached
                        usedResumeBasedHydration = false
                        hydrationSource = "listener+thread/read"
                        appendClosure("Attached to loaded Codex thread without resume: \(id)")
                    } else {
                        appendClosure("Resuming Codex thread: \(id)")
                        result = try await resumeThread(threadId: id)
                    }
                } catch {
                    trace("openSession listener-read failed thread=\(id) error=\(error.localizedDescription)")
                    appendClosure("Attach/read unavailable; falling back to thread/resume for \(id)")
                    result = try await resumeThread(threadId: id)
                    usedResumeBasedHydration = true
                    hydrationSource = "thread/resume-fallback"
                }

                guard isCurrentOpenSessionRequest(requestToken, for: id), !Task.isCancelled else {
                    trace("openSession discard stale-result thread=\(id)")
                    return
                }

                lastResumeAtByThreadId[id] = Date()
                let resumedItems = result.turns.reduce(0) { $0 + $1.items.count }
                trace(
                    "openSession hydrate result source=\(hydrationSource) thread=\(result.id) turns=\(result.turns.count) items=\(resumedItems) activeTurnId=\(result.activeTurnId ?? "nil")"
                )

                let shouldPreserve = shouldPreserveLocalChatState(
                    existingMessages: existingMessages,
                    resumeResult: result
                )
                trace("openSession preserveLocal=\(shouldPreserve)")

                if shouldPreserve {
                    if resumedItems == 0 {
                        currentSessionViewModel?.setSessionContext(serverId: self.id, sessionId: id)
                        if usedResumeBasedHydration || !hadStreamingBeforeResume {
                            applyStreamingStateFromResume(result)
                        } else {
                            trace("openSession preserve streaming source=\(hydrationSource) thread=\(id)")
                        }
                        currentSessionViewModel?.saveChatState()
                        appendClosure("Preserved local chat state for thread \(id)")
                    } else {
                        // Keep rich local tool-call rows while still ingesting newly resumed items.
                        let merge = mergeChatFromThreadHistory(result, preferLocalRichness: true)
                        if usedResumeBasedHydration || !hadStreamingBeforeResume {
                            applyStreamingStateFromResume(result)
                        } else {
                            trace("openSession preserve streaming source=\(hydrationSource) thread=\(id)")
                        }
                        trace(
                            "openSession merged-preserve-local turns=\(merge.resumedTurns) items=\(merge.resumedItems) reused=\(merge.reusedMessages) inserted=\(merge.insertedMessages) updated=\(merge.updatedMessages) unchanged=\(merge.unchangedMessages)"
                        )
                        appendClosure("Merged resumed thread with preserved local richness for thread \(id)")
                    }
                } else {
                    // Populate chat messages from the server response
                    let merge = mergeChatFromThreadHistory(result)
                    if usedResumeBasedHydration || !hadStreamingBeforeResume {
                        applyStreamingStateFromResume(result)
                    } else {
                        trace("openSession preserve streaming source=\(hydrationSource) thread=\(id)")
                    }
                    trace(
                        "openSession merged turns=\(merge.resumedTurns) items=\(merge.resumedItems) reused=\(merge.reusedMessages) inserted=\(merge.insertedMessages) updated=\(merge.updatedMessages) unchanged=\(merge.unchangedMessages)"
                    )
                }

                if usedResumeBasedHydration {
                    schedulePostResumeRefreshIfNeeded(
                        source: "open",
                        threadId: id,
                        existingMessages: existingMessages,
                        resumeResult: result,
                        hadStreamingBeforeResume: hadStreamingBeforeResume
                    )
                } else {
                    trace("postResumeRefresh skip source=open thread=\(id) reason=listenerRead")
                }

                // Update session info
                guard isCurrentOpenSessionRequest(requestToken, for: id), !Task.isCancelled else {
                    trace("openSession discard stale-apply thread=\(id)")
                    return
                }

                if let cwd = result.cwd {
                    rememberSession(id, cwd: cwd)
                } else {
                    rememberSession(id, cwd: nil)
                }
                let resolvedCwd = result.cwd ?? pendingCwd
                fetchSkills(sessionId: id, cwdOverride: resolvedCwd)

                pendingSessionLoad = nil
                if isSessionLoggingEnabled() {
                    let endpoint = endpointURLString
                    let fallbackCwd = workingDirectory
                    Task { [weak self] in
                        await self?.sessionLogger?.startSession(
                            sessionId: id,
                            endpoint: endpoint,
                            cwd: result.cwd ?? fallbackCwd
                        )
                    }
                }
                trace("openSession end thread=\(id) chatMessages=\(currentSessionViewModel?.chatMessages.count ?? -1)")
                appendClosure("Loaded \(result.turns.count) turn(s) from Codex thread via \(hydrationSource)")
            } catch is CancellationError {
                trace("openSession canceled thread=\(id)")
            } catch {
                guard isCurrentOpenSessionRequest(requestToken, for: id), !Task.isCancelled else {
                    trace("openSession ignored stale-failure thread=\(id) error=\(error.localizedDescription)")
                    return
                }
                trace("openSession resume failed thread=\(id) error=\(error.localizedDescription)")
                appendClosure("Failed to resume thread: \(error.localizedDescription) - falling back to local cache")
                // Fall back to local storage if thread/resume fails
                setActiveSession(id, cwd: nil, modes: nil)
            }
        }
    }

    /// Re-establish Codex thread event subscription after foreground reconnect.
    ///
    /// If the active session is still streaming, we avoid resetting chat UI state and
    /// only resubscribe the backend stream + refresh metadata.
    func resubscribeActiveSessionAfterReconnect() {
        guard connectionState == .connected else { return }
        let activeId = sessionId.isEmpty ? (selectedSessionId ?? "") : sessionId
        guard !activeId.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            cancelPostResumeRefreshTask()
            let existingMessages = sessionViewModels[activeId]?.chatMessages ?? []
            let hadStreamingBeforeResume = activeTurnId != nil || existingMessages.contains(where: { $0.isStreaming })
            let pendingCwd = sessionSummaries.first(where: { $0.id == activeId })?.cwd
            trace(
                "resubscribe begin thread=\(activeId) existingMessages=\(existingMessages.count) existingToolCalls=\(countToolCallSegments(in: existingMessages)) hadStreaming=\(hadStreamingBeforeResume)"
            )

            do {
                appendClosure("Re-subscribing Codex thread after reconnect: \(activeId)")

                var usedResumeBasedHydration = true
                var hydrationSource = "thread/resume"
                let result: CodexThreadResumeResult

                do {
                    if let attached = try await attachLoadedThreadAndRead(threadId: activeId) {
                        result = attached
                        usedResumeBasedHydration = false
                        hydrationSource = "listener+thread/read"
                        appendClosure("Reattached to loaded in-memory thread without resume")
                    } else {
                        result = try await resumeThread(threadId: activeId)
                    }
                } catch {
                    trace("resubscribe listener-read failed thread=\(activeId) error=\(error.localizedDescription)")
                    appendClosure("Attach/read unavailable; falling back to thread/resume for \(activeId)")
                    result = try await resumeThread(threadId: activeId)
                    usedResumeBasedHydration = true
                    hydrationSource = "thread/resume-fallback"
                }

                lastResumeAtByThreadId[activeId] = Date()
                let resumedItems = result.turns.reduce(0) { $0 + $1.items.count }
                trace(
                    "resubscribe hydrate result source=\(hydrationSource) thread=\(result.id) turns=\(result.turns.count) items=\(resumedItems) activeTurnId=\(result.activeTurnId ?? "nil")"
                )

                sessionId = activeId
                selectedSessionId = activeId

                let shouldPreserveLocal = shouldPreserveLocalChatState(
                    existingMessages: existingMessages,
                    resumeResult: result
                )
                trace("resubscribe preserveLocal=\(shouldPreserveLocal)")

                if shouldPreserveLocal {
                    if resumedItems == 0 {
                        currentSessionViewModel?.setSessionContext(serverId: self.id, sessionId: activeId)
                        if usedResumeBasedHydration || !hadStreamingBeforeResume {
                            applyStreamingStateFromResume(result)
                        } else {
                            trace("resubscribe preserve streaming source=\(hydrationSource) thread=\(activeId)")
                        }
                        currentSessionViewModel?.saveChatState()
                    } else {
                        // Keep rich local tool-call rows while still ingesting newly resumed items.
                        let merge = mergeChatFromThreadHistory(result, preferLocalRichness: true)
                        if usedResumeBasedHydration || !hadStreamingBeforeResume {
                            applyStreamingStateFromResume(result)
                        } else {
                            trace("resubscribe preserve streaming source=\(hydrationSource) thread=\(activeId)")
                        }
                        trace(
                            "resubscribe merged-preserve-local turns=\(merge.resumedTurns) items=\(merge.resumedItems) reused=\(merge.reusedMessages) inserted=\(merge.insertedMessages) updated=\(merge.updatedMessages) unchanged=\(merge.unchangedMessages)"
                        )
                        appendClosure("Re-subscribed active thread and merged resumed updates with local richness")
                    }
                    if let cwd = result.cwd {
                        rememberSession(activeId, cwd: cwd)
                    } else {
                        rememberSession(activeId, cwd: nil)
                    }
                    let resolvedCwd = result.cwd ?? pendingCwd
                    fetchSkills(sessionId: activeId, cwdOverride: resolvedCwd)
                    if resumedItems == 0 {
                        appendClosure("Re-subscribed active thread and preserved local chat state")
                    }
                } else {
                    let merge = mergeChatFromThreadHistory(result)
                    if usedResumeBasedHydration || !hadStreamingBeforeResume {
                        applyStreamingStateFromResume(result)
                    } else {
                        trace("resubscribe preserve streaming source=\(hydrationSource) thread=\(activeId)")
                    }
                    trace(
                        "resubscribe merged turns=\(merge.resumedTurns) items=\(merge.resumedItems) reused=\(merge.reusedMessages) inserted=\(merge.insertedMessages) updated=\(merge.updatedMessages) unchanged=\(merge.unchangedMessages)"
                    )
                    if let cwd = result.cwd {
                        rememberSession(activeId, cwd: cwd)
                    } else {
                        rememberSession(activeId, cwd: nil)
                    }
                    let resolvedCwd = result.cwd ?? pendingCwd
                    fetchSkills(sessionId: activeId, cwdOverride: resolvedCwd)
                    appendClosure("Re-subscribed active thread and refreshed chat history")
                }

                if usedResumeBasedHydration {
                    schedulePostResumeRefreshIfNeeded(
                        source: "reconnect",
                        threadId: activeId,
                        existingMessages: existingMessages,
                        resumeResult: result,
                        hadStreamingBeforeResume: hadStreamingBeforeResume
                    )
                } else {
                    trace("postResumeRefresh skip source=reconnect thread=\(activeId) reason=listenerRead")
                }

                pendingSessionLoad = nil
                trace("resubscribe end thread=\(activeId) chatMessages=\(currentSessionViewModel?.chatMessages.count ?? -1)")
            } catch {
                trace("resubscribe failed thread=\(activeId) error=\(error.localizedDescription)")
                appendClosure("Failed to re-subscribe active thread: \(error.localizedDescription)")
            }
        }
    }

    private struct ResumeMessageNode {
        let key: String
        let message: ChatMessage
    }

    private struct ResumeHistoryStats {
        var totalItems = 0
        var userMessages = 0
        var agentMessages = 0
        var reasoningItems = 0
        var commandItems = 0
        var fileChangeItems = 0
        var unknownItems = 0
        var emptyAgentMessages = 0
        var emptyUserMessages = 0
    }

    private struct ResumeMergeOutcome {
        let resumedTurns: Int
        let resumedItems: Int
        let reusedMessages: Int
        let insertedMessages: Int
        let updatedMessages: Int
        let unchangedMessages: Int
    }

    private static func hasRenderableMessagePayload(_ message: ChatMessage) -> Bool {
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if !message.images.isEmpty {
            return true
        }
        return message.segments.contains { segment in
            switch segment.kind {
            case .message, .thought, .plan:
                return !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .toolCall:
                let title = segment.toolCall?.title ?? segment.text
                let output = segment.toolCall?.output ?? ""
                return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    private static func mergeResumeMessagePayload(existing: ChatMessage, incoming: ChatMessage) -> ChatMessage {
        let existingRenderable = hasRenderableMessagePayload(existing)
        let incomingRenderable = hasRenderableMessagePayload(incoming)

        // If resume produced a structurally empty item, keep richer in-memory content.
        if existingRenderable, !incomingRenderable {
            var preserved = existing
            preserved.isStreaming = incoming.isStreaming || existing.isStreaming
            preserved.isError = incoming.isError || existing.isError
            return preserved
        }

        // Guard against stale resume snapshots clobbering newer in-memory streaming content.
        if existing.role == .assistant && incoming.role == .assistant {
            let existingText = existing.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let incomingText = incoming.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let existingToolCalls = existing.segments.reduce(into: 0) { count, segment in
                if segment.kind == .toolCall {
                    count += 1
                }
            }
            let incomingToolCalls = incoming.segments.reduce(into: 0) { count, segment in
                if segment.kind == .toolCall {
                    count += 1
                }
            }

            let existingHasToolOutput = existing.segments.contains {
                $0.kind == .toolCall && !($0.toolCall?.output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
            let incomingHasToolOutput = incoming.segments.contains {
                $0.kind == .toolCall && !($0.toolCall?.output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }

            let incomingLooksLikePrefixSnapshot =
                !incomingText.isEmpty
                && existingText.count > incomingText.count
                && existingText.hasPrefix(incomingText)
            let incomingDroppedToolRows =
                existingToolCalls > 0
                && incomingToolCalls == 0
                && existingRenderable
            let incomingDroppedToolOutput =
                existingHasToolOutput
                && !incomingHasToolOutput
                && existingToolCalls >= incomingToolCalls

            if incomingLooksLikePrefixSnapshot || incomingDroppedToolRows || incomingDroppedToolOutput {
                var preserved = existing
                preserved.isStreaming = incoming.isStreaming || existing.isStreaming
                preserved.isError = incoming.isError || existing.isError
                return preserved
            }
        }

        var merged = existing
        merged.content = incoming.content
        merged.segments = incoming.segments
        merged.images = incoming.images
        merged.isError = incoming.isError
        merged.isStreaming = incoming.isStreaming
        return merged
    }

    private static func isResumeMessageRepresentedLocally(candidate: ChatMessage, in existingMessages: [ChatMessage]) -> Bool {
        existingMessages.contains { existing in
            guard existing.role == candidate.role else { return false }
            if existing.content == candidate.content
                && existing.segments == candidate.segments
                && existing.images == candidate.images
                && existing.isError == candidate.isError
            {
                return true
            }

            switch candidate.role {
            case .assistant:
                return isAssistantCandidateRepresentedLocally(candidate: candidate, existing: existing)
            case .user:
                let existingText = ChatMessage.sanitizedUserContent(existing.content).trimmingCharacters(in: .whitespacesAndNewlines)
                let candidateText = ChatMessage.sanitizedUserContent(candidate.content).trimmingCharacters(in: .whitespacesAndNewlines)
                return !existingText.isEmpty && existingText == candidateText
            case .system:
                return false
            }
        }
    }

    private static func isAssistantCandidateRepresentedLocally(candidate: ChatMessage, existing: ChatMessage) -> Bool {
        let candidateText = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingText = existing.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCandidateText = normalizedAssistantText(candidateText)
        let normalizedExistingText = normalizedAssistantText(existingText)
        if !candidateText.isEmpty {
            if existingText == candidateText {
                return true
            }
            if !normalizedCandidateText.isEmpty, normalizedExistingText == normalizedCandidateText {
                return true
            }
            let existingHasToolCall = existing.segments.contains { $0.kind == .toolCall }
            if existingHasToolCall && (
                existingText.contains(candidateText)
                    || (!normalizedCandidateText.isEmpty && normalizedExistingText.contains(normalizedCandidateText))
            ) {
                return true
            }
        }

        let candidateToolCallIDs = Set(
            candidate.segments.compactMap { segment -> String? in
                guard segment.kind == .toolCall else { return nil }
                return segment.toolCall?.toolCallId
            }
        )
        guard !candidateToolCallIDs.isEmpty else { return false }

        let existingToolCallIDs = Set(
            existing.segments.compactMap { segment -> String? in
                guard segment.kind == .toolCall else { return nil }
                return segment.toolCall?.toolCallId
            }
        )
        return candidateToolCallIDs.isSubset(of: existingToolCallIDs)
    }

    private static func normalizedAssistantText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Merge Codex thread history into existing chat while preserving stable row IDs when possible.
    private func mergeChatFromThreadHistory(
        _ result: CodexThreadResumeResult,
        preferLocalRichness: Bool = false
    ) -> ResumeMergeOutcome {
        guard let viewModel = currentSessionViewModel else {
            return ResumeMergeOutcome(
                resumedTurns: result.turns.count,
                resumedItems: result.turns.reduce(0) { $0 + $1.items.count },
                reusedMessages: 0,
                insertedMessages: 0,
                updatedMessages: 0,
                unchangedMessages: 0
            )
        }
        viewModel.setSessionContext(serverId: self.id, sessionId: result.id)

        var stats = ResumeHistoryStats()
        let nodes = buildResumeMessageNodes(result: result, stats: &stats)
        let existingMessages = viewModel.chatMessages
        let existingKeysById = sessionMessageKeys[result.id] ?? [:]

        var existingMessageByKey: [String: ChatMessage] = [:]
        for message in existingMessages {
            guard let key = existingKeysById[message.id], existingMessageByKey[key] == nil else { continue }
            existingMessageByKey[key] = message
        }

        let localRenderableAssistantMessages = existingMessages.filter {
            $0.role == .assistant && Self.hasRenderableMessagePayload($0)
        }.count
        let resumedRenderableAssistantMessages = nodes.filter {
            $0.message.role == .assistant && Self.hasRenderableMessagePayload($0.message)
        }.count
        let localToolCalls = countToolCallSegments(in: existingMessages)
        let resumedToolCalls = nodes.reduce(into: 0) { count, node in
            count += node.message.segments.reduce(into: 0) { segmentCount, segment in
                if segment.kind == .toolCall {
                    segmentCount += 1
                }
            }
        }
        let localRicherThanResume = localRenderableAssistantMessages > resumedRenderableAssistantMessages
            || localToolCalls > resumedToolCalls
        let shouldCarryForwardUnmatchedExisting = preferLocalRichness
            || (result.activeTurnId != nil && localRicherThanResume)
        trace(
            "merge start thread=\(result.id) existingMessages=\(existingMessages.count) nodes=\(nodes.count) localRenderableAssistant=\(localRenderableAssistantMessages) resumedRenderableAssistant=\(resumedRenderableAssistantMessages) localToolCalls=\(localToolCalls) resumedToolCalls=\(resumedToolCalls) activeTurnId=\(result.activeTurnId ?? "nil") carryForward=\(shouldCarryForwardUnmatchedExisting) preferLocal=\(preferLocalRichness)"
        )

        // Bootstrap key mapping by index only when local/resume shapes are compatible.
        // If local has richer unmatched content (e.g. extra tool-call rows), index-based
        // bootstrap can wrongly "reuse" brand-new resumed items and suppress inserts.
        if existingMessageByKey.isEmpty && !shouldCarryForwardUnmatchedExisting {
            let sharedCount = min(existingMessages.count, nodes.count)
            for index in 0..<sharedCount {
                let node = nodes[index]
                let existing = existingMessages[index]
                guard existing.role == node.message.role else { continue }

                switch existing.role {
                case .user:
                    let lhs = ChatMessage.sanitizedUserContent(existing.content).trimmingCharacters(in: .whitespacesAndNewlines)
                    let rhs = ChatMessage.sanitizedUserContent(node.message.content).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !lhs.isEmpty && lhs == rhs {
                        existingMessageByKey[node.key] = existing
                    }
                case .assistant, .system:
                    let sameKinds = existing.segments.map(\.kind) == node.message.segments.map(\.kind)
                    let lhs = existing.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rhs = node.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if sameKinds && (!lhs.isEmpty || !rhs.isEmpty) && lhs == rhs {
                        existingMessageByKey[node.key] = existing
                    }
                }
            }
        }

        struct ResolvedResumeNode {
            let nodeIndex: Int
            let key: String
            let message: ChatMessage
            let reusedExistingId: UUID?
        }

        var resolvedNodes: [ResolvedResumeNode] = []
        resolvedNodes.reserveCapacity(nodes.count)
        var mergedKeysById: [UUID: String] = [:]
        mergedKeysById.reserveCapacity(nodes.count)
        var reusedExistingIds: Set<UUID> = []
        reusedExistingIds.reserveCapacity(existingMessages.count)
        var mergedReusedMessagesById: [UUID: ChatMessage] = [:]
        mergedReusedMessagesById.reserveCapacity(existingMessages.count)
        var reusedMessages = 0
        var insertedMessages = 0
        var updatedMessages = 0
        var unchangedMessages = 0

        for (nodeIndex, node) in nodes.enumerated() {
            if var existing = existingMessageByKey.removeValue(forKey: node.key), existing.role == node.message.role {
                reusedMessages += 1
                let mergedPayload = Self.mergeResumeMessagePayload(existing: existing, incoming: node.message)
                let didChange = existing.content != mergedPayload.content
                    || existing.segments != mergedPayload.segments
                    || existing.images != mergedPayload.images
                    || existing.isError != mergedPayload.isError
                    || existing.isStreaming != mergedPayload.isStreaming
                if didChange {
                    updatedMessages += 1
                } else {
                    unchangedMessages += 1
                }
                existing.content = mergedPayload.content
                existing.segments = mergedPayload.segments
                existing.images = mergedPayload.images
                existing.isError = mergedPayload.isError
                existing.isStreaming = mergedPayload.isStreaming
                reusedExistingIds.insert(existing.id)
                mergedReusedMessagesById[existing.id] = existing
                mergedKeysById[existing.id] = node.key
                resolvedNodes.append(
                    ResolvedResumeNode(
                        nodeIndex: nodeIndex,
                        key: node.key,
                        message: existing,
                        reusedExistingId: existing.id
                    )
                )
            } else {
                insertedMessages += 1
                resolvedNodes.append(
                    ResolvedResumeNode(
                        nodeIndex: nodeIndex,
                        key: node.key,
                        message: node.message,
                        reusedExistingId: nil
                    )
                )
                mergedKeysById[node.message.id] = node.key
            }
        }

        var mergedMessages: [ChatMessage] = resolvedNodes.map(\.message)

        if shouldCarryForwardUnmatchedExisting {
            // Preserve all existing rows in their current order (keeping richer local tool-call rows),
            // then append resume-only rows to the bottom in resume order.
            var baseMessages: [ChatMessage] = []
            baseMessages.reserveCapacity(existingMessages.count + insertedMessages)
            var appendedResumeRows = 0

            for existing in existingMessages {
                if reusedExistingIds.contains(existing.id), let merged = mergedReusedMessagesById[existing.id] {
                    baseMessages.append(merged)
                    mergedKeysById[merged.id] = mergedKeysById[merged.id] ?? (existingKeysById[merged.id] ?? "local:\(merged.id.uuidString)")
                } else {
                    baseMessages.append(existing)
                    mergedKeysById[existing.id] = existingKeysById[existing.id] ?? "local:\(existing.id.uuidString)"
                    reusedMessages += 1
                    unchangedMessages += 1
                }
            }

            for resolved in resolvedNodes where resolved.reusedExistingId == nil {
                let alreadyPresent = Self.isResumeMessageRepresentedLocally(
                    candidate: resolved.message,
                    in: baseMessages
                )
                guard !alreadyPresent else { continue }
                baseMessages.append(resolved.message)
                appendedResumeRows += 1
                mergedKeysById[resolved.message.id] = resolved.key
            }
            insertedMessages = appendedResumeRows

            mergedMessages = baseMessages
        }

        viewModel.setChatMessages(mergedMessages)
        sessionMessageKeys[result.id] = mergedKeysById
        trace(
            "merge end thread=\(result.id) mergedMessages=\(mergedMessages.count) reused=\(reusedMessages) inserted=\(insertedMessages) updated=\(updatedMessages) unchanged=\(unchangedMessages)"
        )

        appendClosure(
            "Codex thread history: turns=\(result.turns.count), items=\(stats.totalItems), user=\(stats.userMessages), agent=\(stats.agentMessages), reasoning=\(stats.reasoningItems), command=\(stats.commandItems), file=\(stats.fileChangeItems), unknown=\(stats.unknownItems), emptyUser=\(stats.emptyUserMessages), emptyAgent=\(stats.emptyAgentMessages)"
        )

        // Save merged state for offline access.
        viewModel.saveChatState()

        return ResumeMergeOutcome(
            resumedTurns: result.turns.count,
            resumedItems: stats.totalItems,
            reusedMessages: reusedMessages,
            insertedMessages: insertedMessages,
            updatedMessages: updatedMessages,
            unchangedMessages: unchangedMessages
        )
    }

    private func buildResumeMessageNodes(
        result: CodexThreadResumeResult,
        stats: inout ResumeHistoryStats
    ) -> [ResumeMessageNode] {
        var nodes: [ResumeMessageNode] = []

        for turn in result.turns {
            for (itemIndex, item) in turn.items.enumerated() {
                stats.totalItems += 1

                switch item {
                case .userMessage(_, let text):
                    stats.userMessages += 1
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        stats.emptyUserMessages += 1
                    }
                    let message = ChatMessage(
                        role: .user,
                        content: ChatMessage.sanitizedUserContent(text),
                        isStreaming: false
                    )
                    nodes.append(
                        ResumeMessageNode(
                            key: resumeNodeKey(turnId: turn.id, itemIndex: itemIndex, item: item),
                            message: message
                        )
                    )

                case .agentMessage(_, let text):
                    stats.agentMessages += 1
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        stats.emptyAgentMessages += 1
                    }
                    let message = ChatMessage(role: .assistant, content: text, isStreaming: false)
                    nodes.append(
                        ResumeMessageNode(
                            key: resumeNodeKey(turnId: turn.id, itemIndex: itemIndex, item: item),
                            message: message
                        )
                    )

                case .plan(_, let text):
                    stats.agentMessages += 1
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        stats.emptyAgentMessages += 1
                        continue
                    }
                    let segment = AssistantSegment(kind: .plan, text: trimmed)
                    let message = ChatMessage(
                        role: .assistant,
                        content: assistantContent(from: [segment]),
                        isStreaming: false,
                        segments: [segment]
                    )
                    nodes.append(
                        ResumeMessageNode(
                            key: resumeNodeKey(turnId: turn.id, itemIndex: itemIndex, item: item),
                            message: message
                        )
                    )

                case .reasoning(_, let text):
                    stats.reasoningItems += 1
                    guard !text.isEmpty else { continue }
                    let segments = [AssistantSegment(kind: .thought, text: text)]
                    let message = ChatMessage(
                        role: .assistant,
                        content: assistantContent(from: segments),
                        isStreaming: false,
                        segments: segments
                    )
                    nodes.append(
                        ResumeMessageNode(
                            key: resumeNodeKey(turnId: turn.id, itemIndex: itemIndex, item: item),
                            message: message
                        )
                    )

                case .commandExecution(let itemId, let command, let output):
                    stats.commandItems += 1
                    let title = command?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayTitle = (title?.isEmpty == false) ? title! : "Command execution"
                    let toolCall = ToolCallDisplay(
                        toolCallId: itemId,
                        title: displayTitle,
                        kind: "execute",
                        status: "completed",
                        output: output
                    )
                    let segment = AssistantSegment(kind: .toolCall, text: displayTitle, toolCall: toolCall)
                    let message = ChatMessage(
                        role: .assistant,
                        content: assistantContent(from: [segment]),
                        isStreaming: false,
                        segments: [segment]
                    )
                    nodes.append(
                        ResumeMessageNode(
                            key: resumeNodeKey(turnId: turn.id, itemIndex: itemIndex, item: item),
                            message: message
                        )
                    )

                case .fileChange(let itemId, let path, let changeType, let diff):
                    stats.fileChangeItems += 1
                    let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let typeLabel = changeType?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayTitle: String
                    if let typeLabel, !typeLabel.isEmpty, let trimmedPath, !trimmedPath.isEmpty {
                        displayTitle = "\(typeLabel): \(trimmedPath)"
                    } else if let trimmedPath, !trimmedPath.isEmpty {
                        displayTitle = trimmedPath
                    } else if let typeLabel, !typeLabel.isEmpty {
                        displayTitle = typeLabel
                    } else {
                        displayTitle = "File change"
                    }
                    let toolCall = ToolCallDisplay(
                        toolCallId: itemId,
                        title: displayTitle,
                        kind: "edit",
                        status: "completed",
                        output: diff
                    )
                    let segment = AssistantSegment(kind: .toolCall, text: displayTitle, toolCall: toolCall)
                    let message = ChatMessage(
                        role: .assistant,
                        content: assistantContent(from: [segment]),
                        isStreaming: false,
                        segments: [segment]
                    )
                    nodes.append(
                        ResumeMessageNode(
                            key: resumeNodeKey(turnId: turn.id, itemIndex: itemIndex, item: item),
                            message: message
                        )
                    )

                case .toolCall(let itemId, let title, let kind, let status, let output):
                    stats.commandItems += 1
                    let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let effectiveTitle = displayTitle.isEmpty ? "Tool call" : displayTitle
                    let toolCall = ToolCallDisplay(
                        toolCallId: itemId,
                        title: effectiveTitle,
                        kind: kind,
                        status: status ?? "completed",
                        output: output
                    )
                    let segment = AssistantSegment(kind: .toolCall, text: effectiveTitle, toolCall: toolCall)
                    let message = ChatMessage(
                        role: .assistant,
                        content: assistantContent(from: [segment]),
                        isStreaming: false,
                        segments: [segment]
                    )
                    nodes.append(
                        ResumeMessageNode(
                            key: resumeNodeKey(turnId: turn.id, itemIndex: itemIndex, item: item),
                            message: message
                        )
                    )

                case .unknown(let type):
                    stats.unknownItems += 1
                    appendClosure("Unknown Codex item type: \(type)")
                }
            }
        }

        return nodes
    }

    private func resumeNodeKey(turnId: String, itemIndex: Int, item: CodexThreadResumeResult.Item) -> String {
        switch item {
        case .reasoning(let itemId, _):
            if let itemId, !itemId.isEmpty { return "turn:\(turnId):reasoning:\(itemId)" }
            return "turn:\(turnId):idx:\(itemIndex):reasoning"
        case .commandExecution(let itemId, _, _):
            if let itemId, !itemId.isEmpty { return "turn:\(turnId):command:\(itemId)" }
            return "turn:\(turnId):idx:\(itemIndex):command"
        case .fileChange(let itemId, _, _, _):
            if let itemId, !itemId.isEmpty { return "turn:\(turnId):file:\(itemId)" }
            return "turn:\(turnId):idx:\(itemIndex):file"
        case .toolCall(let itemId, _, _, _, _):
            if let itemId, !itemId.isEmpty { return "turn:\(turnId):tool:\(itemId)" }
            return "turn:\(turnId):idx:\(itemIndex):tool"
        case .userMessage(let itemId, _):
            if let itemId, !itemId.isEmpty { return "turn:\(turnId):user:\(itemId)" }
            return "turn:\(turnId):idx:\(itemIndex):user"
        case .agentMessage(let itemId, _):
            if let itemId, !itemId.isEmpty { return "turn:\(turnId):assistant:\(itemId)" }
            return "turn:\(turnId):idx:\(itemIndex):assistant"
        case .plan(let itemId, _):
            if let itemId, !itemId.isEmpty { return "turn:\(turnId):plan:\(itemId)" }
            return "turn:\(turnId):idx:\(itemIndex):plan"
        case .unknown(let type):
            return "turn:\(turnId):idx:\(itemIndex):unknown:\(type)"
        }
    }

    private func assistantContent(from segments: [AssistantSegment]) -> String {
        let lines = segments.compactMap { segment -> String? in
            switch segment.kind {
            case .message, .thought, .plan:
                return segment.text
            case .toolCall:
                let displayTitle: String
                if let toolCall = segment.toolCall, let kind = toolCall.kind, !kind.isEmpty {
                    displayTitle = "[\(kind)] \(toolCall.title)"
                } else {
                    displayTitle = segment.toolCall?.title ?? segment.text
                }
                guard !displayTitle.isEmpty else { return nil }
                if let status = segment.toolCall?.status, !status.isEmpty {
                    return "Tool call: \(displayTitle) (\(status))"
                }
                return "Tool call: \(displayTitle)"
            }
        }
        return lines.joined(separator: "\n")
    }

    func sendLoadSession(_ sessionIdToLoad: String, cwd: String?) {
        // Codex uses thread/resume instead of session/load
        // Redirect to openSession which handles this properly
        appendClosure("Codex app-server: using thread/resume to load session")
        openSession(sessionIdToLoad)
    }

    func sendNewSession(workingDirectory: String?) {
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

            do {
                let sanitizedCwd = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
                let configuredCwd = sanitizedCwd?.isEmpty == false ? sanitizedCwd! : self.workingDirectory

                // Fetch models if not already loaded
                if availableModels.isEmpty {
                    fetchModels()
                }

                // Fetch skills for the new session's working directory
                fetchSkills()

                let threadId = try await startThread(cwd: configuredCwd)
                setActiveSession(threadId, cwd: configuredCwd, modes: nil)
                connectionManager.markSessionMaterialized(threadId)
                rememberUsedWorkingDirectory(configuredCwd)
                persistSessionsToStorage()
                appendClosure("Created Codex thread: \(threadId)")
            } catch {
                appendClosure("Failed to create Codex thread: \(error.localizedDescription)")
            }
        }
    }

    func deleteSession(_ sessionId: String) {
        sessionSummaries.removeAll { $0.id == sessionId }
        setSessionSummaries(sessionSummaries)

        cacheDelegate?.clearCache(for: id, sessionId: sessionId)
        currentSessionViewModel?.removeCommands(for: id, sessionId: sessionId)

        if self.sessionId == sessionId {
            cancelPostResumeRefreshTask()
            self.sessionId = ""
            self.selectedSessionId = nil
            self.activeThreadId = nil
            self.activeTurnId = nil
            currentSessionViewModel?.resetChatState()
            Task { await sessionLogger?.endSession() }
        }

        removeSessionViewModel(for: sessionId)
        storage?.deleteSession(sessionId: sessionId, forServerId: id)
    }

    func archiveSession(_ sessionId: String) {
        guard !sessionId.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.archiveThread(threadId: sessionId)
                appendClosure("Archived Codex thread: \(sessionId)")
            } catch {
                appendClosure("Failed to archive thread: \(error.localizedDescription)")
                return
            }

            // Remove from local state after successful server archive
            sessionSummaries.removeAll { $0.id == sessionId }
            setSessionSummaries(sessionSummaries)

            cacheDelegate?.clearCache(for: id, sessionId: sessionId)
            currentSessionViewModel?.removeCommands(for: id, sessionId: sessionId)

            if self.sessionId == sessionId {
                self.sessionId = ""
                self.selectedSessionId = nil
                currentSessionViewModel?.resetChatState()
                Task { await sessionLogger?.endSession() }
            }

            removeSessionViewModel(for: sessionId)
            storage?.deleteSession(sessionId: sessionId, forServerId: id)
        }
    }

    func sendPrompt(promptText: String, images: [ImageAttachment], commandName: String?) {
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
                appendClosure("Create or load a thread first")
                return
            }

            cancelPostResumeRefreshTask()
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

            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, images.isEmpty {
                appendClosure("Cannot send empty prompt")
                failPendingTurn("Cannot send empty prompt")
                return
            }

            // Show user message immediately
            let chatImages = images.map { ChatImageData(from: $0) }
            currentSessionViewModel?.addUserMessage(content: prompt, images: chatImages)
            currentSessionViewModel?.startNewStreamingResponse()

            if !isInitialized {
                if let payload = connectionManager.initializationPayloadProvider?() {
                    let initialized = await connectionManager.initializeAndWait(payload: payload)
                    guard initialized else {
                        appendClosure("Initialize needed but not yet completed")
                        failPendingTurn("Initialize needed")
                        return
                    }
                } else {
                    appendClosure("Initialize needed but not yet completed")
                    failPendingTurn("Initialize needed")
                    return
                }
            }

            if !images.isEmpty {
                appendClosure("Codex app-server: image attachments are not supported yet; sending text only")
            }

            do {
                // Convert enabled skill names to array if any are selected
                let skillNames = enabledSkillNames.isEmpty ? nil : Array(enabledSkillNames)

                try await startTurn(
                    threadId: sessionId,
                    text: prompt,
                    model: selectedModelId,
                    effort: selectedEffort,
                    skills: skillNames,
                    isPlanMode: isPlanModeEnabled,
                    approvalPolicy: permissionPreset.turnApprovalPolicy,
                    sandboxPolicy: permissionPreset.turnSandboxPolicy
                )
                bumpSessionTimestamp(sessionId: sessionId)
                updateSessionTitleIfNeeded(with: prompt)
            } catch {
                appendClosure("Failed to send Codex prompt: \(error.localizedDescription)")
                failPendingTurn(formatPromptError(error))
            }
        }
    }

    func interruptActiveTurn() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard getServiceClosure() != nil else {
                appendClosure("Not connected")
                return
            }
            guard connectionState == .connected else {
                appendClosure("Not connected")
                return
            }
            guard !sessionId.isEmpty else {
                appendClosure("No active thread")
                return
            }
            guard let turnId = activeTurnId else {
                currentSessionViewModel?.finishStreamingMessage()
                appendClosure("No active turn to interrupt")
                return
            }

            do {
                try await interruptTurn(threadId: sessionId, turnId: turnId)
                activeTurnId = nil
                currentSessionViewModel?.finishStreamingMessage()
                appendClosure("Interrupted active turn")
            } catch {
                appendClosure("Failed to interrupt turn: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Session List

    func fetchSessionList(force: Bool = false) {
        guard connectionState == .connected, let service = getServiceClosure() else {
            loadCachedSessions()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let summaries = try await listThreads(limit: 50)
                setSessionSummaries(summaries)
                if var info = agentInfo {
                    info.capabilities.listSessions = true
                    agentInfo = info
                }
                persistSessionsToStorage()
                appendClosure("Fetched \(sessionSummaries.count) Codex thread(s)")
            } catch {
                appendClosure("Failed to fetch Codex threads: \(error.localizedDescription)")
                loadCachedSessions()
            }
        }
    }

    func handleSessionListResult(_ sessions: [SessionSummary]) {
        // Called by AppViewModel for ACP - for Codex we fetch directly
        setSessionSummaries(sessions)
    }

    func loadCachedSessions() {
        if !sessionSummaryCache.isEmpty {
            sessionSummaries = sessionSummaryCache
        } else if let storage = storage {
            let storedSessions = storage.fetchSessions(forServerId: id)
            if !storedSessions.isEmpty {
                let summaries = storedSessions.map { $0.toSessionSummary() }
                sessionSummaries = summaries
                appendClosure("Loaded \(storedSessions.count) persisted thread(s) from storage")
            } else {
                sessionSummaries = []
            }
        } else {
            sessionSummaries = []
        }
    }

    func hasCachedMessages(sessionId: String) -> Bool {
        return cacheDelegate?.loadMessages(for: id, sessionId: sessionId)?.isEmpty == false
    }

    // MARK: - Private Helpers

    private func failPendingTurn(_ message: String) {
        currentSessionViewModel?.abandonStreamingMessage()
        currentSessionViewModel?.addSystemErrorMessage(message)
    }

    private func hasStreamingAssistantMessage(in sessionId: String?) -> Bool {
        guard let sessionId, !sessionId.isEmpty else { return false }
        return sessionViewModels[sessionId]?.chatMessages.contains(where: { $0.isStreaming }) ?? false
    }

    private func shouldPreserveLocalChatState(
        existingMessages: [ChatMessage],
        resumeResult: CodexThreadResumeResult
    ) -> Bool {
        guard !existingMessages.isEmpty else { return false }
        let resumedItems = resumeResult.turns.reduce(into: 0) { count, turn in
            count += turn.items.count
        }
        if resumedItems == 0 {
            trace("preserveLocal=true reason=resumedItems0 existingMessages=\(existingMessages.count)")
            return true
        }

        let localToolCalls = countToolCallSegments(in: existingMessages)
        let resumedToolCalls = countToolCallItems(in: resumeResult)
        if localToolCalls > resumedToolCalls {
            trace("preserveLocal=true reason=toolCallDelta localToolCalls=\(localToolCalls) resumedToolCalls=\(resumedToolCalls)")
            return true
        }

        let localAssistantMessages = existingMessages.filter { $0.role == .assistant }.count
        let resumedAssistantMessages = countAssistantMessages(in: resumeResult)
        if localAssistantMessages > resumedAssistantMessages && localToolCalls >= resumedToolCalls {
            trace("preserveLocal=true reason=assistantDelta localAssistant=\(localAssistantMessages) resumedAssistant=\(resumedAssistantMessages)")
            return true
        }
        trace("preserveLocal=false reason=default localAssistant=\(localAssistantMessages) resumedAssistant=\(resumedAssistantMessages) localToolCalls=\(localToolCalls) resumedToolCalls=\(resumedToolCalls)")
        return false
    }

    private func postResumeRefreshAttemptCount(
        existingMessages: [ChatMessage],
        resumeResult: CodexThreadResumeResult,
        hadStreamingBeforeResume: Bool
    ) -> Int {
        // Always do at least one follow-up resume to converge eventual consistency
        // after app foreground/reconnect/open-session transitions.
        if resumeResult.activeTurnId != nil {
            return hadStreamingBeforeResume ? 2 : 1
        }

        let localToolCalls = countToolCallSegments(in: existingMessages)
        let resumedToolCalls = countToolCallItems(in: resumeResult)
        let localAssistantMessages = existingMessages.filter { $0.role == .assistant }.count
        let resumedAssistantMessages = countAssistantMessages(in: resumeResult)

        if localToolCalls > resumedToolCalls { return 3 }
        if localAssistantMessages > resumedAssistantMessages && localToolCalls >= resumedToolCalls { return 3 }
        if hadStreamingBeforeResume && resumedAssistantMessages == 0 && resumedToolCalls == 0 { return 3 }
        return 1
    }

    private func schedulePostResumeRefreshIfNeeded(
        source: String,
        threadId: String,
        existingMessages: [ChatMessage],
        resumeResult: CodexThreadResumeResult,
        hadStreamingBeforeResume: Bool
    ) {
        let attemptLimit = postResumeRefreshAttemptCount(
            existingMessages: existingMessages,
            resumeResult: resumeResult,
            hadStreamingBeforeResume: hadStreamingBeforeResume
        )
        guard attemptLimit > 0 else {
            trace("postResumeRefresh skip source=\(source) thread=\(threadId)")
            return
        }

        cancelPostResumeRefreshTask()
        let initialItems = resumeResult.turns.reduce(into: 0) { count, turn in
            count += turn.items.count
        }
        trace(
            "postResumeRefresh scheduled source=\(source) thread=\(threadId) attempts=\(attemptLimit) initialItems=\(initialItems) localMessages=\(existingMessages.count)"
        )

        postResumeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var previousItems = initialItems
            var stableRounds = 0

            for attempt in 1...attemptLimit {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }

                guard connectionState == .connected else {
                    trace("postResumeRefresh stop reason=disconnected source=\(source) thread=\(threadId) attempt=\(attempt)")
                    return
                }

                guard sessionId == threadId || selectedSessionId == threadId else {
                    trace("postResumeRefresh stop reason=threadChanged source=\(source) thread=\(threadId) attempt=\(attempt)")
                    return
                }

                do {
                    let refreshed = try await resumeThread(threadId: threadId)
                    let refreshedItems = refreshed.turns.reduce(into: 0) { count, turn in
                        count += turn.items.count
                    }
                    let merge = mergeChatFromThreadHistory(refreshed, preferLocalRichness: true)
                    applyStreamingStateFromResume(refreshed)
                    trace(
                        "postResumeRefresh apply source=\(source) thread=\(threadId) attempt=\(attempt) items=\(refreshedItems) activeTurnId=\(refreshed.activeTurnId ?? "nil")"
                    )

                    if refreshed.activeTurnId != nil {
                        return
                    }

                    if refreshedItems <= previousItems {
                        stableRounds += 1
                    } else {
                        stableRounds = 0
                    }
                    previousItems = max(previousItems, refreshedItems)

                    if stableRounds >= 1 {
                        return
                    }
                } catch {
                    trace(
                        "postResumeRefresh failed source=\(source) thread=\(threadId) attempt=\(attempt) error=\(error.localizedDescription)"
                    )
                    return
                }
            }
        }
    }

    private func cancelPostResumeRefreshTask() {
        postResumeRefreshTask?.cancel()
        postResumeRefreshTask = nil
    }

    private func beginOpenSessionRequest(_ id: String, cwd: String?) -> UInt64 {
        cancelOpenSessionTask()

        openSessionRequestToken &+= 1
        let requestToken = openSessionRequestToken

        pendingSessionLoad = id
        sessionId = id
        selectedSessionId = id
        activeThreadId = id
        activeTurnId = nil
        reasoningCache.removeAll()
        currentSessionViewModel?.setSessionContext(serverId: self.id, sessionId: id)
        rememberSession(id, cwd: cwd)

        return requestToken
    }

    private func isCurrentOpenSessionRequest(_ requestToken: UInt64, for id: String) -> Bool {
        requestToken == openSessionRequestToken && sessionId == id && selectedSessionId == id
    }

    private func cancelOpenSessionTask() {
        openSessionTask?.cancel()
        openSessionTask = nil
    }

    private func applyStreamingStateFromResume(_ result: CodexThreadResumeResult) {
        guard let viewModel = currentSessionViewModel else { return }
        let hadStreamingMessage = viewModel.chatMessages.contains(where: { $0.isStreaming })

        if result.activeTurnId != nil {
            if !viewModel.chatMessages.contains(where: { $0.isStreaming }) {
                _ = viewModel.ensureStreamingAssistantMessage()
            }
        } else if viewModel.chatMessages.contains(where: { $0.isStreaming }) {
            viewModel.finishStreamingMessage()
        }
        let hasStreamingMessage = viewModel.chatMessages.contains(where: { $0.isStreaming })
        trace(
            "applyStreamingStateFromResume activeTurnId=\(result.activeTurnId ?? "nil") hadStreamingMessage=\(hadStreamingMessage) hasStreamingMessage=\(hasStreamingMessage)"
        )
    }

    private func countToolCallSegments(in messages: [ChatMessage]) -> Int {
        messages.reduce(into: 0) { count, message in
            count += message.segments.reduce(into: 0) { segmentCount, segment in
                if segment.kind == .toolCall {
                    segmentCount += 1
                }
            }
        }
    }

    private func countToolCallItems(in result: CodexThreadResumeResult) -> Int {
        result.turns.reduce(into: 0) { count, turn in
            count += turn.items.reduce(into: 0) { itemCount, item in
                switch item {
                case .commandExecution, .fileChange, .toolCall:
                    itemCount += 1
                default:
                    break
                }
            }
        }
    }

    private func countAssistantMessages(in result: CodexThreadResumeResult) -> Int {
        result.turns.reduce(into: 0) { count, turn in
            count += turn.items.reduce(into: 0) { itemCount, item in
                switch item {
                case .agentMessage, .reasoning, .commandExecution, .fileChange, .toolCall:
                    itemCount += 1
                case .plan:
                    itemCount += 1
                case .userMessage, .unknown:
                    break
                }
            }
        }
    }

    private func formatPromptError(_ error: Error) -> String {
        if let serviceError = error as? ACPServiceError, let message = serviceError.rpcMessage {
            return message
        }
        return error.localizedDescription
    }

    @discardableResult
    private func rememberSession(_ sessionId: String, cwd: String? = nil) -> Bool {
        guard !sessionId.isEmpty else { return false }
        let now = Date()

        let existingSession = sessionSummaries.first(where: { $0.id == sessionId })
        let timestamp = existingSession?.updatedAt ?? now
        let title = existingSession?.title

        if let index = sessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            let existing = sessionSummaries[index]
            if cwd != nil && existing.cwd != cwd {
                sessionSummaries[index] = SessionSummary(
                    id: existing.id,
                    title: existing.title,
                    cwd: cwd,
                    updatedAt: existing.updatedAt
                )
                setSessionSummaries(sessionSummaries)
            }
        } else {
            sessionSummaries.insert(SessionSummary(id: sessionId, title: nil, cwd: cwd, updatedAt: now), at: 0)
            setSessionSummaries(sessionSummaries)
        }

        let sessionInfo = StoredSessionInfo(sessionId: sessionId, title: title, cwd: cwd, updatedAt: timestamp)
        storage?.saveSession(sessionInfo, forServerId: id)
        if let cwd {
            rememberUsedWorkingDirectory(cwd)
        }
        return false
    }

    @discardableResult
    private func rememberUsedWorkingDirectory(_ cwd: String) -> Bool {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return storage?.addUsedWorkingDirectory(trimmed, forServerId: id) ?? false
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

    private func setSessionSummaries(_ summaries: [SessionSummary]) {
        // Preserve previously known fields (cwd) when the latest server payload omits them.
        // Older Codex servers may omit cwd in thread/list, so a fresh fetch would otherwise
        // wipe out cached working directories until the user re-opens each session.
        let existing = sessionSummaries

        // Also hydrate from persisted storage so initial connected load can show cwd
        // without requiring the user to open each session first.
        let storedSessions = storage?.fetchSessions(forServerId: id) ?? []
        var cachedCwdById: [String: String] = [:]
        for session in storedSessions {
            if let cwd = session.cwd {
                cachedCwdById[session.sessionId] = cwd
            }
        }
        for session in existing {
            if let cwd = session.cwd {
                cachedCwdById[session.id] = cwd
            }
        }

        let merged = summaries.map { summary in
            guard summary.cwd == nil,
                  let cached = cachedCwdById[summary.id] else {
                return summary
            }
            return SessionSummary(
                id: summary.id,
                title: summary.title,
                cwd: cached,
                updatedAt: summary.updatedAt
            )
        }

        let sorted = sortSessionSummaries(merged)
        sessionSummaries = sorted
        sessionSummaryCache = sorted
    }

    private func persistSessionsToStorage() {
        let sessions = sessionSummaries

        for session in sessions {
            let storedInfo = StoredSessionInfo(
                sessionId: session.id,
                title: session.title,
                cwd: session.cwd,
                updatedAt: session.updatedAt
            )
            storage?.saveSession(storedInfo, forServerId: id)
        }
    }

    private func bumpSessionTimestamp(sessionId: String, timestamp: Date = Date()) {
        let cwd = sessionSummaries.first(where: { $0.id == sessionId })?.cwd

        if let index = sessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            let existing = sessionSummaries[index]
            let updated = SessionSummary(id: existing.id, title: existing.title, cwd: existing.cwd ?? cwd, updatedAt: timestamp)
            sessionSummaries.remove(at: index)
            sessionSummaries.insert(updated, at: 0)
        } else {
            sessionSummaries.insert(SessionSummary(id: sessionId, title: nil, cwd: cwd, updatedAt: timestamp), at: 0)
        }

        setSessionSummaries(sessionSummaries)
        storage?.updateSession(sessionId: sessionId, forServerId: id, title: nil, touchUpdatedAt: true)
    }

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

        storage?.updateSession(sessionId: sessionId, forServerId: id, title: title, touchUpdatedAt: true)
    }

    // MARK: - Codex RPC Helpers

    private func callCodex(method: String, params: JSONValue?) async throws -> JSONRPCResponse {
        guard let service = getServiceClosure() else {
            throw ACPServiceError.disconnected
        }
        await ensureInitializedAck()
        return try await service.callJSONRPC(method: method, params: params)
    }

    private func startThread(cwd: String?, approvalPolicy: String = "untrusted") async throws -> String {
        var params: [String: JSONValue] = [
            "approvalPolicy": .string(approvalPolicy),
            // Persist richer rollout history so cold app relaunch can restore tool-call rows.
            "persistExtendedHistory": .bool(true),
        ]
        if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["cwd"] = .string(cwd)
        }
        let response = try await callCodex(method: "thread/start", params: .object(params))
        guard let resultObj = response.result?.objectValue,
              let threadObj = resultObj["thread"]?.objectValue,
              let id = threadObj["id"]?.stringValue,
              !id.isEmpty
        else {
            throw ACPServiceError.unsupportedMessage
        }
        activeThreadId = id
        activeTurnId = nil
        return id
    }

    private func startTurn(
        threadId: String,
        text: String,
        model: String?,
        effort: String?,
        skills: [String]?,
        isPlanMode: Bool = false,
        approvalPolicy: String? = nil,
        sandboxPolicy: JSONValue? = nil
    ) async throws {
        let input: JSONValue = .array([
            .object([
                "type": .string("text"),
                "text": .string(text),
            ]),
        ])
        var params: [String: JSONValue] = [
            "threadId": .string(threadId),
            "input": input,
        ]
        if let model { params["model"] = .string(model) }
        if let effort { params["effort"] = .string(effort) }
        if let skills, !skills.isEmpty {
            params["skills"] = .array(skills.map { .string($0) })
        }
        if let approvalPolicy {
            params["approvalPolicy"] = .string(approvalPolicy)
        }
        if let sandboxPolicy {
            params["sandboxPolicy"] = sandboxPolicy
        }
        if let collaborationMode = collaborationModePayload(
            isPlanMode: isPlanMode,
            modelOverride: model
        ) {
            params["collaborationMode"] = collaborationMode
        }

        let response = try await callCodex(method: "turn/start", params: .object(params))
        activeThreadId = threadId
        activeTurnId = response.result?.objectValue?["turn"]?.objectValue?["id"]?.stringValue
    }

    func collaborationModePayload(isPlanMode: Bool, modelOverride: String?) -> JSONValue? {
        guard let modelId = firstNonEmptyOptionalString(
            modelOverride,
            selectedModel?.id,
            defaultModel?.id
        ) else {
            return nil
        }

        return .object([
            "mode": .string(isPlanMode ? "plan" : "default"),
            "settings": .object([
                "model": .string(modelId),
                "reasoning_effort": .null,
                "developer_instructions": .null,
            ]),
        ])
    }

    private func interruptTurn(threadId: String, turnId: String) async throws {
        _ = try await callCodex(
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadId),
                "turnId": .string(turnId),
            ])
        )
    }

    private func resumeThread(threadId: String) async throws -> CodexThreadResumeResult {
        let response = try await callCodex(
            method: "thread/resume",
            params: .object([
                "threadId": .string(threadId),
                // Keep history persistence mode sticky after reconnect/open paths.
                "persistExtendedHistory": .bool(true),
            ])
        )
        guard let result = parseThreadResume(result: response.result) else {
            throw ACPServiceError.unsupportedMessage
        }
        activeThreadId = result.id
        activeTurnId = result.activeTurnId
        return result
    }

    private func readThread(threadId: String, includeTurns: Bool = true) async throws -> CodexThreadResumeResult {
        let response = try await callCodex(
            method: "thread/read",
            params: .object([
                "threadId": .string(threadId),
                "includeTurns": .bool(includeTurns),
            ])
        )
        guard let result = parseThreadResume(result: response.result) else {
            throw ACPServiceError.unsupportedMessage
        }
        activeThreadId = result.id
        return result
    }

    private func listLoadedThreads(limit: Int = 200) async throws -> [String] {
        var loaded: [String] = []
        var cursor: String? = nil

        while true {
            var params: [String: JSONValue] = ["limit": .number(Double(limit))]
            if let cursor {
                params["cursor"] = .string(cursor)
            } else {
                params["cursor"] = .null
            }

            let response = try await callCodex(
                method: "thread/loaded/list",
                params: .object(params)
            )
            guard let object = response.result?.objectValue else { break }
            if case let .array(data)? = object["data"] {
                for value in data {
                    if let id = value.stringValue, !id.isEmpty {
                        loaded.append(id)
                    }
                }
            }

            guard let next = object["nextCursor"]?.stringValue, !next.isEmpty else { break }
            cursor = next
        }

        return loaded
    }

    private func isThreadLoaded(threadId: String) async throws -> Bool {
        let loaded = try await listLoadedThreads()
        return loaded.contains(threadId)
    }

    private func addConversationListener(threadId: String) async throws {
        _ = try await callCodex(
            method: "addConversationListener",
            params: .object([
                "conversationId": .string(threadId),
                "experimentalRawEvents": .bool(false),
            ])
        )
    }

    private func attachLoadedThreadAndRead(threadId: String) async throws -> CodexThreadResumeResult? {
        guard try await isThreadLoaded(threadId: threadId) else { return nil }
        try await addConversationListener(threadId: threadId)
        return try await readThread(threadId: threadId, includeTurns: true)
    }

    private func listThreads(limit: Int = 50) async throws -> [SessionSummary] {
        let response = try await callCodex(
            method: "thread/list",
            params: .object([
                "cursor": .null,
                "limit": .number(Double(limit)),
            ])
        )
        return parseThreadList(result: response.result)
    }

    private func archiveThread(threadId: String) async throws {
        _ = try await callCodex(
            method: "thread/archive",
            params: .object(["threadId": .string(threadId)])
        )
    }

    private func listModels(limit: Int = 50) async throws -> [AppServerModel] {
        let response = try await callCodex(
            method: "model/list",
            params: .object([
                "cursor": .null,
                "limit": .number(Double(limit)),
            ])
        )
        return parseModels(result: response.result)
    }

    private func listSkills(cwds: [String]? = nil, forceReload: Bool = false) async throws -> [AppServerSkill] {
        var params: [String: JSONValue] = [:]
        if let cwds, !cwds.isEmpty {
            params["cwds"] = .array(cwds.map { .string($0) })
        }
        if forceReload { params["forceReload"] = .bool(true) }

        let response = try await callCodex(method: "skills/list", params: params.isEmpty ? nil : .object(params))
        return parseSkills(result: response.result)
    }

    private func respondToApprovalRequest(
        requestId: JSONRPCID,
        decision: String,
        acceptForSession: Bool? = nil
    ) async {
        var payload: [String: JSONValue] = ["decision": .string(decision)]
        if let acceptForSession {
            payload["acceptSettings"] = .object(["forSession": .bool(acceptForSession)])
        }
        let response = JSONRPCMessage.response(JSONRPCResponse(id: requestId, result: .object(payload)))
        do {
            try await service?.sendMessage(response)
        } catch {
            // Best-effort.
        }
    }

    func approveRequest(requestId: JSONRPCID, acceptForSession: Bool? = nil) {
        currentSessionViewModel?.clearApprovalRequest(requestId)
        Task { @MainActor in
            await respondToApprovalRequest(requestId: requestId, decision: "accept", acceptForSession: acceptForSession)
        }
    }

    func declineRequest(requestId: JSONRPCID) {
        currentSessionViewModel?.clearApprovalRequest(requestId)
        Task { @MainActor in
            await respondToApprovalRequest(requestId: requestId, decision: "decline")
        }
    }

    // MARK: - User Input Requests (Plan Mode)

    private func handleRequestUserInput(_ request: JSONRPCRequest) {
        guard let params = request.params?.objectValue else { return }
        guard case .array(let questionsArray) = params["questions"] else { return }

        var questions: [UserInputQuestion] = []
        for q in questionsArray {
            guard let qObj = q.objectValue else { continue }
            let questionId = qObj["id"]?.stringValue ?? UUID().uuidString
            let header = qObj["header"]?.stringValue ?? ""
            let text = qObj["question"]?.stringValue ?? qObj["text"]?.stringValue ?? ""
            let multiSelect = qObj["multiSelect"]?.boolValue ?? false
            var options: [UserInputOption] = []
            if case .array(let optionsArray) = qObj["options"] {
                for opt in optionsArray {
                    if let optObj = opt.objectValue {
                        let label = optObj["label"]?.stringValue ?? ""
                        let description = optObj["description"]?.stringValue
                        let isOther = optObj["isOther"]?.boolValue ?? false
                        let isSecret = optObj["isSecret"]?.boolValue ?? false
                        options.append(UserInputOption(label: label, description: description, isOther: isOther, isSecret: isSecret))
                    }
                }
            }
            questions.append(
                UserInputQuestion(
                    id: questionId,
                    header: header,
                    text: text,
                    options: options,
                    multiSelect: multiSelect
                )
            )
        }

        guard !questions.isEmpty else { return }
        currentSessionViewModel?.addUserInputRequest(
            requestId: request.id,
            questions: questions
        )
    }

    func respondToUserInputRequest(requestId: JSONRPCID, answers: [String: [String]]) {
        Task { @MainActor in
            var answersPayload: [String: JSONValue] = [:]
            for (questionId, selectedAnswers) in answers {
                answersPayload[questionId] = .object([
                    "answers": .array(selectedAnswers.map { .string($0) }),
                ])
            }
            let payload: [String: JSONValue] = ["answers": .object(answersPayload)]
            let response = JSONRPCMessage.response(JSONRPCResponse(id: requestId, result: .object(payload)))
            do {
                try await service?.sendMessage(response)
            } catch {
                // Best-effort.
            }
        }
    }

    // MARK: - Codex Message Handling

    /// Handle Codex-specific messages (notifications from the backend).
    func handleCodexMessage(_ message: JSONRPCMessage) {
        switch message {
        case .notification(let notification):
            guard let params = notification.params?.objectValue else { return }
            let threadId = params["threadId"]?.stringValue
            let turnId = params["turnId"]?.stringValue
            trace(
                "notif method=\(notification.method) threadId=\(threadId ?? "nil") turnId=\(turnId ?? "nil") activeThread=\(activeThreadId ?? "nil") activeTurn=\(activeTurnId ?? "nil")"
            )
            if let activeThreadId, let threadId, threadId != activeThreadId {
                trace("notif dropped reason=threadMismatch method=\(notification.method) threadId=\(threadId) activeThread=\(activeThreadId)")
                return
            }

            switch notification.method {
            case "turn/diff/updated":
                if let diff = params["diff"]?.stringValue, !diff.isEmpty {
                    let turnId = params["turnId"]?.stringValue
                    handleTurnDiffUpdated(diff: diff, turnId: turnId)
                }
            case "codex/event/turn_diff":
                if let msg = params["msg"]?.objectValue,
                   let diff = msg["unified_diff"]?.stringValue,
                   !diff.isEmpty {
                    let turnId = params["id"]?.stringValue ?? msg["id"]?.stringValue
                    handleTurnDiffUpdated(diff: diff, turnId: turnId)
                }
            case "item/agentMessage/delta":
                alignActiveTurnIfNeeded(
                    incomingTurnId: params["turnId"]?.stringValue,
                    method: "item/agentMessage/delta",
                    ensureStreamingMessage: true
                )
                if let delta = params["delta"]?.stringValue {
                    trace("notif apply method=item/agentMessage/delta chars=\(delta.count)")
                    currentSessionViewModel?.appendAssistantText(delta, kind: .message)
                }
            case "item/plan/delta":
                handlePlanDeltaNotification(params, method: "item/plan/delta")
            case "item/started":
                let turnId = params["turnId"]?.stringValue
                alignActiveTurnIfNeeded(
                    incomingTurnId: turnId,
                    method: "item/started",
                    ensureStreamingMessage: true
                )
                if let itemValue = params["item"] {
                    trace("notif apply method=item/started")
                    handleCodexItemEvent(itemValue, status: "in_progress", turnId: turnId)
                }
            case "item/completed":
                let turnId = params["turnId"]?.stringValue
                alignActiveTurnIfNeeded(
                    incomingTurnId: turnId,
                    method: "item/completed",
                    ensureStreamingMessage: false
                )
                if let itemValue = params["item"] {
                    trace("notif apply method=item/completed")
                    handleCodexItemEvent(itemValue, status: "completed", turnId: turnId)
                }
            case "turn/plan/updated":
                handleTurnPlanUpdatedNotification(params)
            case "turn/completed":
                let turnObject = params["turn"]?.objectValue
                let completedTurnId = turnObject?["id"]?.stringValue
                if let activeTurnId, let completedTurnId, completedTurnId != activeTurnId {
                    trace("notif dropped reason=turnMismatch method=turn/completed turnId=\(completedTurnId) activeTurn=\(activeTurnId)")
                    return
                }
                if isSessionLoggingEnabled() {
                    Task {
                        await sessionLogger?.logTurnEvent(
                            type: "turn_completed",
                            sessionId: sessionId.isEmpty ? nil : sessionId,
                            turnId: completedTurnId ?? activeTurnId
                        )
                    }
                }
                activeTurnId = nil
                currentSessionViewModel?.finishStreamingMessage()
                trace("notif apply method=turn/completed newActiveTurn=nil")
                if let serverId = selectedSessionId {
                    eventDelegate?.sessionDidReceiveStopReason("turn_completed", serverId: id, sessionId: serverId)
                }
            case "turn/started":
                if let turnId = params["turn"]?.objectValue?["id"]?.stringValue {
                    cancelPostResumeRefreshTask()
                    activeTurnId = turnId
                    _ = currentSessionViewModel?.ensureStreamingAssistantMessage()
                    trace("notif apply method=turn/started newActiveTurn=\(turnId)")
                    if isSessionLoggingEnabled() {
                        Task {
                            await sessionLogger?.logTurnEvent(
                                type: "turn_started",
                                sessionId: sessionId.isEmpty ? nil : sessionId,
                                turnId: turnId
                            )
                        }
                    }
                }
            case "error":
                handleErrorNotification(params)
            default:
                break
            }

        case .request(let request):
            switch request.method {
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                // Approval requests are handled by handleApprovalRequest from AppViewModel.
                break
            case "item/tool/requestUserInput":
                handleRequestUserInput(request)
            default:
                break
            }

        case .response, .error:
            break
        }
    }

    private func handleErrorNotification(_ params: [String: JSONValue]) {
        let errorObject = params["error"]?.objectValue
        let errorMessage = errorObject?["message"]?.stringValue
            ?? params["message"]?.stringValue
            ?? "Unknown error"
        let willRetry = params["willRetry"]?.boolValue ?? false

        appendClosure("Codex error notification: \(errorMessage) (willRetry=\(willRetry))")

        if willRetry {
            // Transient error — the server will auto-retry; show as informational
            currentSessionViewModel?.appendAssistantText("\n\n⚠️ \(errorMessage) (retrying…)\n\n", kind: .message)
        } else {
            // Terminal error — stop streaming and show the error
            activeTurnId = nil
            currentSessionViewModel?.finishStreamingMessage()
            currentSessionViewModel?.addSystemErrorMessage(errorMessage)
        }
    }

    private func handleTurnDiffUpdated(diff: String, turnId: String?) {
        guard let viewModel = currentSessionViewModel else { return }
        let path = extractPathFromUnifiedDiff(diff) ?? "CHANGELOG.md"
        let title = "diff: \(path)"
        let toolCallId = turnId.map { "turn_diff:\($0)" }
        viewModel.upsertToolCallFromAppServer(
            toolCallId: toolCallId,
            title: title,
            kind: "edit",
            status: "completed",
            output: diff
        )
    }

    private func extractPathFromUnifiedDiff(_ diff: String) -> String? {
        for line in diff.split(separator: "\n") {
            guard line.hasPrefix("diff --git ") else { continue }
            let parts = line.split(separator: " ")
            guard parts.count >= 4 else { continue }
            let aPath = String(parts[2])
            let bPath = String(parts[3])
            let cleaned = bPath.hasPrefix("b/") ? String(bPath.dropFirst(2)) : bPath
            if cleaned != "/dev/null" {
                return cleaned
            }
            let fallback = aPath.hasPrefix("a/") ? String(aPath.dropFirst(2)) : aPath
            return fallback == "/dev/null" ? nil : fallback
        }
        return nil
    }

    private func handlePlanDeltaNotification(_ params: [String: JSONValue], method: String) {
        let turnId = firstNonEmptyOptionalString(
            params["turnId"]?.stringValue,
            params["turn_id"]?.stringValue,
            params["id"]?.stringValue
        )
        alignActiveTurnIfNeeded(
            incomingTurnId: turnId,
            method: method,
            ensureStreamingMessage: true
        )

        guard let delta = extractPlanDeltaText(from: params), !delta.isEmpty else { return }
        trace("notif apply method=\(method) chars=\(delta.count)")
        currentSessionViewModel?.appendAssistantText(delta, kind: .plan)
    }

    private func handleTurnPlanUpdatedNotification(_ params: [String: JSONValue]) {
        let turnId = params["turnId"]?.stringValue
        alignActiveTurnIfNeeded(
            incomingTurnId: turnId,
            method: "turn/plan/updated",
            ensureStreamingMessage: true
        )

        guard let text = buildPlanText(from: params),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        currentSessionViewModel?.completePlanItem(id: turnId, text: text)
        trace("notif apply method=turn/plan/updated chars=\(text.count)")
    }

    private func extractPlanDeltaText(from params: [String: JSONValue]) -> String? {
        if let delta = params["delta"]?.stringValue { return delta }
        if let text = params["text"]?.stringValue { return text }
        if let content = params["content"]?.stringValue { return content }
        if let message = params["message"]?.stringValue { return message }
        return nil
    }

    private func buildPlanText(from params: [String: JSONValue]) -> String? {
        let explanation = params["explanation"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var stepLines: [String] = []

        if case let .array(planItems)? = params["plan"] {
            for planItem in planItems {
                guard let planObject = planItem.objectValue else { continue }
                guard let formatted = formatPlanStep(planObject) else { continue }
                stepLines.append(formatted)
            }
        }

        if let explanation, !explanation.isEmpty, !stepLines.isEmpty {
            return "\(explanation)\n\n" + stepLines.joined(separator: "\n")
        }
        if !stepLines.isEmpty {
            return stepLines.joined(separator: "\n")
        }
        if let explanation, !explanation.isEmpty {
            return explanation
        }
        return nil
    }

    private func formatPlanStep(_ stepObject: [String: JSONValue]) -> String? {
        let step = stepObject["step"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = stepObject["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = stepObject["status"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let core: String
        if !step.isEmpty && !description.isEmpty {
            core = step == description ? step : "\(step): \(description)"
        } else if !step.isEmpty {
            core = step
        } else if !description.isEmpty {
            core = description
        } else {
            return nil
        }

        if !status.isEmpty {
            return "- \(core) (\(status))"
        }
        return "- \(core)"
    }

    private func handleCodexItemEvent(_ itemValue: JSONValue, status: String, turnId: String?) {
        guard let viewModel = currentSessionViewModel else { return }
        guard let item = parseThreadItem(itemValue) else { return }
        let currentSessionId = sessionId.isEmpty ? nil : sessionId
        let loggingEnabled = isSessionLoggingEnabled()

        switch item {
        case .reasoning(let itemId, let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let itemId, !itemId.isEmpty {
                let previous = reasoningCache[itemId]
                if previous != trimmed {
                    viewModel.appendAssistantText(trimmed, kind: .thought)
                    reasoningCache[itemId] = trimmed
                    if loggingEnabled {
                        Task { await sessionLogger?.logReasoning(sessionId: currentSessionId, turnId: turnId, itemId: itemId, text: trimmed) }
                    }
                }
            } else {
                viewModel.appendAssistantText(trimmed, kind: .thought)
                if loggingEnabled {
                    Task { await sessionLogger?.logReasoning(sessionId: currentSessionId, turnId: turnId, itemId: itemId, text: trimmed) }
                }
            }

        case .commandExecution(let itemId, let command, let output):
            let title = command?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = (title?.isEmpty == false) ? title! : "Command execution"
            let outputValue = status == "completed" ? output : nil
            viewModel.upsertToolCallFromAppServer(
                toolCallId: itemId,
                title: displayTitle,
                kind: "execute",
                status: status,
                output: outputValue
            )
            if loggingEnabled {
                Task {
                    await sessionLogger?.logCommandExecution(
                        sessionId: currentSessionId,
                        turnId: turnId,
                        itemId: itemId,
                        command: command,
                        output: outputValue
                    )
                }
            }

        case .fileChange(let itemId, let path, let changeType, let diff):
            let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
            let typeLabel = changeType?.trimmingCharacters(in: .whitespacesAndNewlines)
            appendClosure("Codex fileChange item id=\(itemId ?? "nil") path=\(trimmedPath ?? "nil") type=\(typeLabel ?? "nil") diffChars=\(diff?.count ?? 0)")
            let displayTitle: String
            if let typeLabel, !typeLabel.isEmpty, let trimmedPath, !trimmedPath.isEmpty {
                displayTitle = "\(typeLabel): \(trimmedPath)"
            } else if let trimmedPath, !trimmedPath.isEmpty {
                displayTitle = trimmedPath
            } else if let typeLabel, !typeLabel.isEmpty {
                displayTitle = typeLabel
            } else {
                displayTitle = "File change"
            }
            let outputValue = (diff?.isEmpty == false) ? diff : nil
            viewModel.upsertToolCallFromAppServer(
                toolCallId: itemId,
                title: displayTitle,
                kind: "edit",
                status: status,
                output: outputValue
            )
            if loggingEnabled {
                Task {
                    await sessionLogger?.logFileChange(
                        sessionId: currentSessionId,
                        turnId: turnId,
                        itemId: itemId,
                        path: trimmedPath,
                        changeType: typeLabel,
                        diff: status == "completed" ? diff : nil
                    )
                }
            }

        case .toolCall(let itemId, let title, let kind, let itemStatus, let output):
            let effectiveTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveStatus = itemStatus ?? status
            viewModel.upsertToolCallFromAppServer(
                toolCallId: itemId,
                title: effectiveTitle.isEmpty ? "Tool call" : effectiveTitle,
                kind: kind,
                status: effectiveStatus,
                output: output
            )
            if loggingEnabled {
                Task {
                    await sessionLogger?.logToolCall(
                        sessionId: currentSessionId,
                        turnId: turnId,
                        itemId: itemId,
                        title: effectiveTitle.isEmpty ? "Tool call" : effectiveTitle,
                        kind: kind,
                        status: effectiveStatus,
                        output: output
                    )
                }
            }

        case .plan(_, let text):
            applyPlanItem(text, status: status, to: viewModel)

        case .agentMessage(_, let text):
            applyAgentMessageItem(text, status: status, to: viewModel)

        case .userMessage, .unknown:
            break
        }
    }

    private func applyAgentMessageItem(_ text: String, status: String, to viewModel: ACPSessionViewModel) {
        if let planText = extractProposedPlanText(from: text) {
            applyPlanItem(planText, status: status, to: viewModel)
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        trace("item agentMessage status=\(status) chars=\(trimmed.count)")

        // When deltas already built a streaming message, item/completed often carries
        // the full final text. Append only the missing suffix to avoid duplication.
        if let last = viewModel.chatMessages.last, last.role == .assistant, last.isStreaming {
            let existing = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if existing == trimmed || existing.hasSuffix(trimmed) {
                return
            }
            if !existing.isEmpty, trimmed.hasPrefix(existing) {
                let suffix = String(trimmed.dropFirst(existing.count))
                if !suffix.isEmpty {
                    viewModel.appendAssistantText(suffix, kind: .message)
                }
                return
            }
        }

        if status == "completed" || status == "in_progress" {
            viewModel.appendAssistantText(trimmed, kind: .message)
            trace("item agentMessage appended status=\(status)")
        }
    }

    private func applyPlanItem(_ text: String, status: String, to viewModel: ACPSessionViewModel) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        trace("item plan status=\(status) chars=\(trimmed.count)")

        if let last = viewModel.chatMessages.last,
           last.role == .assistant,
           last.isStreaming,
           let lastPlanSegment = last.segments.last,
           lastPlanSegment.kind == .plan
        {
            let existing = lastPlanSegment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if existing == trimmed || existing.hasSuffix(trimmed) {
                return
            }
            if !existing.isEmpty, trimmed.hasPrefix(existing) {
                let suffix = String(trimmed.dropFirst(existing.count))
                if !suffix.isEmpty {
                    viewModel.appendAssistantText(suffix, kind: .plan)
                }
                return
            }
        }

        if status == "completed" {
            viewModel.completePlanItem(id: nil, text: trimmed)
            trace("item plan completed")
        } else if status == "in_progress" {
            viewModel.appendAssistantText(trimmed, kind: .plan)
            trace("item plan appended status=\(status)")
        }
    }

    private func extractProposedPlanText(from text: String) -> String? {
        guard let regex = Self.proposedPlanRegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let bodyRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let extracted = text[bodyRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return extracted.isEmpty ? nil : extracted
    }

    private func alignActiveTurnIfNeeded(
        incomingTurnId: String?,
        method: String,
        ensureStreamingMessage: Bool
    ) {
        guard let incomingTurnId, !incomingTurnId.isEmpty else { return }
        if activeTurnId == incomingTurnId { return }
        let previous = activeTurnId ?? "nil"
        activeTurnId = incomingTurnId
        if ensureStreamingMessage {
            _ = currentSessionViewModel?.ensureStreamingAssistantMessage()
        }
        trace("notif alignTurn method=\(method) from=\(previous) to=\(incomingTurnId)")
    }

    private func trace(_ message: String) {
#if DEBUG
        print("[CodexResumeDebug][\(id.uuidString.prefix(6))] \(message)")
#endif
    }

    /// Handle incoming approval request from Codex app-server.
    func handleApprovalRequest(_ request: JSONRPCRequest) {
        guard let params = request.params?.objectValue else {
            appendClosure("Codex approval: \(request.method) missing params")
            return
        }

        let toolCallId = params["itemId"]?.stringValue
        let reason = params["reason"]?.stringValue
        let command = params["command"]?.stringValue
        let cwd = params["cwd"]?.stringValue

        let approvalKind: String
        let displayKind: String?
        let displayTitle: String

        if request.method.contains("commandExecution") {
            approvalKind = "commandExecution"
            displayKind = "command"
            displayTitle = command ?? "Command execution"
        } else if request.method.contains("fileChange") {
            approvalKind = "fileChange"
            displayKind = "file"
            displayTitle = "File change"
        } else {
            approvalKind = request.method
            displayKind = "tool"
            displayTitle = "Approval required"
        }

        currentSessionViewModel?.updateToolCallWithApproval(
            toolCallId: toolCallId,
            title: displayTitle,
            kind: displayKind,
            requestId: request.id,
            approvalKind: approvalKind,
            reason: reason,
            command: command,
            cwd: cwd
        )

        appendClosure("Codex approval requested: \(request.method) (awaiting user)")
    }

    // MARK: - Parsing Helpers

    private func parseThreadList(result: JSONValue?) -> [SessionSummary] {
        guard let object = result?.objectValue else { return [] }
        guard case let .array(data)? = object["data"] else { return [] }

        return data.compactMap { value in
            guard let thread = value.objectValue else { return nil }
            guard let id = thread["id"]?.stringValue, !id.isEmpty else { return nil }
            let preview = thread["preview"]?.stringValue
            let cwd = thread["cwd"]?.stringValue ?? thread["workingDirectory"]?.stringValue
            let updatedAt = parseUnixDate(thread["updatedAt"]) ?? parseUnixDate(thread["createdAt"])
            return SessionSummary(id: id, title: preview, cwd: cwd, updatedAt: updatedAt)
        }
    }

    private func parseModels(result: JSONValue?) -> [AppServerModel] {
        guard let object = result?.objectValue else { return [] }
        guard case let .array(data)? = object["data"] else { return [] }

        return data.compactMap { value in
            guard let modelObj = value.objectValue else { return nil }
            guard let id = modelObj["id"]?.stringValue else { return nil }
            guard let model = modelObj["model"]?.stringValue else { return nil }
            let displayName = modelObj["displayName"]?.stringValue ?? model
            let description = modelObj["description"]?.stringValue ?? ""
            let isDefault = modelObj["isDefault"]?.boolValue ?? false
            let defaultEffort = modelObj["defaultReasoningEffort"]?.stringValue ?? "medium"

            var efforts: [AppServerReasoningEffortOption] = []
            if case let .array(effortsArray)? = modelObj["supportedReasoningEfforts"] {
                efforts = effortsArray.compactMap { effortValue in
                    guard let effortObj = effortValue.objectValue else { return nil }
                    guard let effort = effortObj["reasoningEffort"]?.stringValue else { return nil }
                    let desc = effortObj["description"]?.stringValue ?? ""
                    return AppServerReasoningEffortOption(reasoningEffort: effort, description: desc)
                }
            }

            return AppServerModel(
                id: id,
                model: model,
                displayName: displayName,
                description: description,
                supportedReasoningEfforts: efforts,
                defaultReasoningEffort: defaultEffort,
                isDefault: isDefault
            )
        }
    }

    private func parseSkills(result: JSONValue?) -> [AppServerSkill] {
        guard let object = result?.objectValue else { return [] }
        guard case let .array(data)? = object["data"] else { return [] }

        var all: [AppServerSkill] = []
        for entry in data {
            guard let entryObj = entry.objectValue else { continue }
            guard case let .array(skillsArray)? = entryObj["skills"] else { continue }

            for skillValue in skillsArray {
                guard let skillObj = skillValue.objectValue else { continue }
                guard let name = skillObj["name"]?.stringValue else { continue }
                let description = skillObj["description"]?.stringValue ?? ""
                let shortDescription = skillObj["shortDescription"]?.stringValue
                let path = skillObj["path"]?.stringValue ?? ""
                let scopeStr = skillObj["scope"]?.stringValue ?? "repo"
                let scope = AppServerSkillScope(rawValue: scopeStr) ?? .repo

                all.append(AppServerSkill(
                    name: name,
                    description: description,
                    shortDescription: shortDescription,
                    path: path,
                    scope: scope
                ))
            }
        }

        return all.sorted { ($0.scope, $0.name) < ($1.scope, $1.name) }
    }

    private func parseThreadResume(result: JSONValue?) -> CodexThreadResumeResult? {
        guard let object = result?.objectValue else { return nil }
        guard let thread = object["thread"]?.objectValue else { return nil }
        guard let id = thread["id"]?.stringValue, !id.isEmpty else { return nil }

        let preview = thread["preview"]?.stringValue
        let cwd = thread["cwd"]?.stringValue ?? object["cwd"]?.stringValue
        let createdAt = parseUnixDate(thread["createdAt"])

        var activeTurnId: String?
        var turns: [CodexThreadResumeResult.Turn] = []
        if case let .array(turnsArray)? = thread["turns"] {
            for turnValue in turnsArray {
                guard let turnObj = turnValue.objectValue else { continue }
                guard let turnId = turnObj["id"]?.stringValue else { continue }
                let status = turnObj["status"]?.stringValue
                if activeTurnId == nil, isTurnInProgressStatus(status) {
                    activeTurnId = turnId
                }

                var items: [CodexThreadResumeResult.Item] = []
                if case let .array(itemsArray)? = turnObj["items"] {
                    for itemValue in itemsArray {
                        if let item = parseThreadItem(itemValue) {
                            items.append(item)
                        }
                    }
                }

                turns.append(CodexThreadResumeResult.Turn(id: turnId, status: status, items: items))
            }
        }

        return CodexThreadResumeResult(
            id: id,
            preview: preview,
            cwd: cwd,
            createdAt: createdAt,
            activeTurnId: activeTurnId,
            turns: turns
        )
    }

    private func parseUnixDate(_ value: JSONValue?) -> Date? {
        if let raw = value?.numberValue {
            return Date(timeIntervalSince1970: normalizeUnixTimestampToSeconds(raw))
        }
        if let rawString = value?.stringValue, let raw = Double(rawString) {
            return Date(timeIntervalSince1970: normalizeUnixTimestampToSeconds(raw))
        }
        return nil
    }

    private func normalizeUnixTimestampToSeconds(_ raw: Double) -> TimeInterval {
        if raw >= 1e17 {
            return raw / 1_000_000_000.0
        }
        if raw >= 1e14 {
            return raw / 1_000_000.0
        }
        if raw >= 1e11 {
            return raw / 1_000.0
        }
        return raw
    }

    private func isTurnInProgressStatus(_ status: String?) -> Bool {
        guard let status else { return false }
        let normalized = status.replacingOccurrences(of: "_", with: "").lowercased()
        return normalized == "inprogress"
            || normalized == "running"
            || normalized == "pending"
            || normalized == "started"
    }

    private func parseThreadItem(_ value: JSONValue) -> CodexThreadResumeResult.Item? {
        guard let obj = value.objectValue else { return nil }
        guard let type = obj["type"]?.stringValue else { return nil }
        let itemId = obj["id"]?.stringValue
        let normalizedType = type.replacingOccurrences(of: "_", with: "").lowercased()

        switch normalizedType {
        case "usermessage":
            let text = extractTextContent(from: obj)
            return .userMessage(id: itemId, text: text)
        case "message":
            let role = obj["role"]?.stringValue?.lowercased()
            let text = extractTextContent(from: obj)
            if role?.contains("user") == true {
                return .userMessage(id: itemId, text: text)
            }
            if role?.contains("assistant") == true || role?.contains("agent") == true || role == nil {
                return .agentMessage(id: itemId, text: text)
            }
            return .agentMessage(id: itemId, text: text)
        case "agentmessage", "assistantmessage":
            let directText = obj["text"]?.stringValue ?? ""
            let contentText = extractTextContent(from: obj)
            let text = directText.isEmpty ? contentText : directText
            return .agentMessage(id: itemId, text: text)
        case "plan":
            let text = extractTextContent(from: obj)
            return .plan(id: itemId, text: text)
        case "reasoning", "thought", "analysis":
            let text = extractReasoningText(from: obj)
            return .reasoning(id: itemId, text: text)
        case "commandexecution", "command", "exec", "shell":
            let command = obj["command"]?.stringValue
            let output = obj["output"]?.stringValue
            return .commandExecution(id: itemId, command: command, output: output)
        case "filechange", "file", "diff", "patch":
            let (path, changeType, diff) = extractFileChangeDetails(from: obj)
            appendClosure("Codex fileChange parsed id=\(itemId ?? "nil") path=\(path ?? "nil") type=\(changeType ?? "nil") diffChars=\(diff?.count ?? 0)")
            return .fileChange(id: itemId, path: path, changeType: changeType, diff: diff)
        case "toolcall", "tool", "functioncall", "function":
            return parseGenericToolCall(id: itemId, type: type, object: obj)
        default:
            if normalizedType.contains("assistant") || normalizedType.contains("agent") {
                return .agentMessage(id: itemId, text: extractTextContent(from: obj))
            }
            if normalizedType.contains("user") {
                return .userMessage(id: itemId, text: extractTextContent(from: obj))
            }
            if normalizedType.contains("plan") {
                return .plan(id: itemId, text: extractTextContent(from: obj))
            }
            if normalizedType.contains("reason") || normalizedType.contains("thought") || normalizedType.contains("analysis") {
                let text = extractReasoningText(from: obj)
                return .reasoning(id: itemId, text: text)
            }
            if normalizedType.contains("command") || normalizedType.contains("exec") || normalizedType.contains("shell") {
                let command = obj["command"]?.stringValue ?? obj["name"]?.stringValue
                let output = extractToolOutput(from: obj)
                return .commandExecution(id: itemId, command: command, output: output)
            }
            if normalizedType.contains("file") || normalizedType.contains("patch") || normalizedType.contains("diff") {
                let (path, changeType, diff) = extractFileChangeDetails(from: obj)
                appendClosure("Codex fileChange parsed id=\(itemId ?? "nil") path=\(path ?? "nil") type=\(changeType ?? "nil") diffChars=\(diff?.count ?? 0)")
                return .fileChange(id: itemId, path: path, changeType: changeType, diff: diff)
            }
            if normalizedType.contains("tool") || normalizedType.contains("function") {
                return parseGenericToolCall(id: itemId, type: type, object: obj)
            }
            return .unknown(type: type)
        }
    }

    private func parseGenericToolCall(id: String?, type: String, object: [String: JSONValue]) -> CodexThreadResumeResult.Item {
        let title = firstNonEmptyString(
            object["title"]?.stringValue,
            object["name"]?.stringValue,
            object["toolName"]?.stringValue,
            object["command"]?.stringValue,
            object["path"]?.stringValue,
            object["tool"]?.objectValue?["name"]?.stringValue,
            type
        )
        let kind = firstNonEmptyString(
            object["kind"]?.stringValue,
            object["toolType"]?.stringValue,
            object["tool"]?.objectValue?["type"]?.stringValue,
            object["name"]?.stringValue
        )
        let status = firstNonEmptyString(
            object["status"]?.stringValue,
            object["state"]?.stringValue
        )
        let output = extractToolOutput(from: object)

        return .toolCall(
            id: id,
            title: title,
            kind: kind,
            status: status,
            output: output
        )
    }

    private func extractReasoningText(from object: [String: JSONValue]) -> String {
        let directText = object["text"]?.stringValue
        let contentText = extractTextContent(from: object)
        if let directText, !directText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return directText
        }
        if !contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return contentText
        }
        let summaryItems = stringArray(from: object["summary"])
        if !summaryItems.isEmpty {
            return summaryItems.joined(separator: "\n\n")
        }
        return ""
    }

    private func extractToolOutput(from object: [String: JSONValue]) -> String? {
        if case let .array(outputArray)? = object["output"] {
            var parts: [String] = []
            for outputValue in outputArray {
                if let scalar = stringValue(from: outputValue), !scalar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(scalar)
                    continue
                }
                guard let outputObject = outputValue.objectValue else { continue }
                if let text = firstNonEmptyOptionalString(
                    outputObject["text"]?.stringValue,
                    outputObject["delta"]?.stringValue,
                    outputObject["result"]?.stringValue,
                    outputObject["content"]?.stringValue
                ) {
                    parts.append(text)
                    continue
                }
                let nested = extractTextContent(from: outputObject).trimmingCharacters(in: .whitespacesAndNewlines)
                if !nested.isEmpty {
                    parts.append(nested)
                }
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n")
            }
        }

        if case let .object(outputObject)? = object["output"] {
            let nestedStdout = stringValue(from: outputObject["stdout"])
            let nestedStderr = stringValue(from: outputObject["stderr"])
            let nestedDirect = firstNonEmptyOptionalString(
                stringValue(from: outputObject["text"]),
                stringValue(from: outputObject["result"])
            )
            if let nestedDirect {
                return nestedDirect
            }
            if let nestedStdout, let nestedStderr, !nestedStdout.isEmpty || !nestedStderr.isEmpty {
                let combined = [nestedStdout, nestedStderr].filter { !$0.isEmpty }.joined(separator: "\n")
                return combined.isEmpty ? nil : combined
            }
        }

        let direct = firstNonEmptyOptionalString(
            stringValue(from: object["output"]),
            stringValue(from: object["result"]),
            stringValue(from: object["response"])
        )
        let stdout = stringValue(from: object["stdout"])
        let stderr = stringValue(from: object["stderr"])
        if let direct {
            return direct
        }
        if let stdout, let stderr, !stdout.isEmpty || !stderr.isEmpty {
            let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            return combined.isEmpty ? nil : combined
        }
        return nil
    }

    private func extractDiffText(from object: [String: JSONValue]) -> String? {
        if let diff = object["diff"]?.stringValue, !diff.isEmpty {
            return diff
        }
        if let patch = object["patch"]?.stringValue, !patch.isEmpty {
            return patch
        }
        if case let .array(changesArray)? = object["changes"] {
            for changeItem in changesArray {
                guard let changeObj = changeItem.objectValue else { continue }
                if let diff = changeObj["diff"]?.stringValue, !diff.isEmpty {
                    return diff
                }
            }
        }
        if case let .array(contentArray)? = object["content"] {
            var parts: [String] = []
            for contentItem in contentArray {
                guard let contentObj = contentItem.objectValue else { continue }
                let type = contentObj["type"]?.stringValue?.lowercased()
                let text = contentObj["text"]?.stringValue
                if let type, ["diff", "patch"].contains(type), let text, !text.isEmpty {
                    parts.append(text)
                }
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n")
            }
        }
        return nil
    }

    private func extractFileChangeDetails(from object: [String: JSONValue]) -> (path: String?, changeType: String?, diff: String?) {
        if case let .array(changesArray)? = object["changes"] {
            for changeItem in changesArray {
                guard let changeObj = changeItem.objectValue else { continue }
                let path = changeObj["path"]?.stringValue
                let kind = firstNonEmptyString(
                    changeObj["kind"]?.stringValue,
                    changeObj["changeType"]?.stringValue
                )
                let diff = extractDiffText(from: changeObj)
                if path != nil || diff != nil || !kind.isEmpty {
                    let normalizedKind = kind == "Tool call" ? nil : kind
                    return (path, normalizedKind, diff)
                }
            }
        }

        let path = object["path"]?.stringValue
        let changeType = object["changeType"]?.stringValue
        let diff = extractDiffText(from: object)
        return (path, changeType, diff)
    }

    private func stringValue(from value: JSONValue?) -> String? {
        switch value {
        case .string(let text):
            return text
        case .number(let number):
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        default:
            return nil
        }
    }

    private func stringArray(from value: JSONValue?) -> [String] {
        guard case let .array(items)? = value else { return [] }
        return items.compactMap { item in
            if case let .string(text) = item {
                return text
            }
            return nil
        }
    }

    private func firstNonEmptyString(_ values: String?...) -> String {
        firstNonEmptyOptionalString(values) ?? "Tool call"
    }

    private func firstNonEmptyOptionalString(_ values: String?...) -> String? {
        firstNonEmptyOptionalString(values)
    }

    private func firstNonEmptyOptionalString(_ values: [String?]) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func extractTextContent(from object: [String: JSONValue]) -> String {
        var textParts: [String] = []
        if case let .array(contentArray)? = object["content"] {
            for contentItem in contentArray {
                if let scalar = stringValue(from: contentItem),
                   !scalar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textParts.append(scalar)
                    continue
                }

                guard let contentObj = contentItem.objectValue else { continue }
                let type = contentObj["type"]?.stringValue?.lowercased()
                let isTextType = type == nil
                    || type == "text"
                    || type == "input_text"
                    || type == "output_text"
                    || type == "message"
                if !isTextType { continue }

                if let text = contentObj["text"]?.stringValue, !text.isEmpty {
                    textParts.append(text)
                    continue
                }
                if let delta = contentObj["delta"]?.stringValue, !delta.isEmpty {
                    textParts.append(delta)
                    continue
                }
                if let textObject = contentObj["text"]?.objectValue,
                   let nested = firstNonEmptyOptionalString(
                    textObject["value"]?.stringValue,
                    textObject["text"]?.stringValue
                   ) {
                    textParts.append(nested)
                    continue
                }
            }
        }

        if !textParts.isEmpty {
            return textParts.joined(separator: "\n")
        }

        if let directText = object["text"]?.stringValue, !directText.isEmpty {
            return directText
        }
        if let delta = object["delta"]?.stringValue, !delta.isEmpty {
            return delta
        }
        if let message = object["message"]?.stringValue, !message.isEmpty {
            return message
        }
        if let textObject = object["text"]?.objectValue,
           let nested = firstNonEmptyOptionalString(
            textObject["value"]?.stringValue,
            textObject["text"]?.stringValue
           ) {
            return nested
        }
        if let output = extractToolOutput(from: object),
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return output
        }

        return ""
    }
}

// MARK: - ACPSessionEventDelegate

extension CodexServerViewModel: ACPSessionEventDelegate {
    func sessionModeDidChange(_ modeId: String, serverId: UUID, sessionId: String) {
        appendClosure("Mode changed to: \(modeId)")
    }

    func sessionDidReceiveStopReason(_ reason: String, serverId: UUID, sessionId: String) {
        appendClosure("Turn stopReason: \(reason)")
    }

    func sessionLoadDidComplete(serverId: UUID, sessionId: String) {
        lastLoadedSession = sessionId
    }
}
