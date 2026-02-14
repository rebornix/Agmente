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
        currentSessionViewModel?.chatMessages.contains(where: { $0.isStreaming }) ?? false
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

    // MARK: - Private State

    private let connectionManager: ACPClientManager
    private var service: ACPService? { connectionManager.service }

    private var sessionSummaryCache: [SessionSummary] = []

    private var activeThreadId: String?
    private var activeTurnId: String?
    private var needsInitializedAck: Bool = false
    private var reasoningCache: [String: String] = [:]

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
    }

    func removeAllSessionViewModels() {
        sessionViewModels.removeAll()
        for cancellable in sessionViewModelCancellables.values {
            cancellable.cancel()
        }
        sessionViewModelCancellables.removeAll()
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
            case userMessage(String)
            case agentMessage(String)
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
        // For Codex, we use thread/resume to fetch full history from server
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let service = getServiceClosure() else {
                appendClosure("Not connected - falling back to local cache")
                setActiveSession(id, cwd: nil, modes: nil)
                return
            }
            guard connectionState == .connected else {
                appendClosure("Not connected - falling back to local cache")
                setActiveSession(id, cwd: nil, modes: nil)
                return
            }

            do {
                // Fetch models if not already loaded
                if availableModels.isEmpty {
                    fetchModels()
                }

                let pendingCwd = sessionSummaries.first(where: { $0.id == id })?.cwd

                appendClosure("Resuming Codex thread: \(id)")

                let result = try await resumeThread(threadId: id)

                // Set the session active without loading from Core Data
                sessionId = id
                selectedSessionId = id

                // Populate chat messages from the server response
                populateChatFromThreadHistory(result)

                // Update session info
                if let cwd = result.cwd {
                    rememberSession(id, cwd: cwd)
                } else {
                    rememberSession(id, cwd: nil)
                }
                let resolvedCwd = result.cwd ?? pendingCwd
                fetchSkills(sessionId: id, cwdOverride: resolvedCwd)

                pendingSessionLoad = nil
                if isSessionLoggingEnabled() {
                    Task { await sessionLogger?.startSession(sessionId: id, endpoint: endpointURLString, cwd: result.cwd ?? workingDirectory) }
                }
                appendClosure("Loaded \(result.turns.count) turn(s) from Codex thread")
            } catch {
                appendClosure("Failed to resume thread: \(error.localizedDescription) - falling back to local cache")
                // Fall back to local storage if thread/resume fails
                setActiveSession(id, cwd: nil, modes: nil)
            }
        }
    }

    /// Populate chat messages from Codex thread history.
    private func populateChatFromThreadHistory(_ result: CodexThreadResumeResult) {
        guard let viewModel = currentSessionViewModel else { return }

        // Clear existing messages and populate from server
        viewModel.resetChatState()
        viewModel.setSessionContext(serverId: self.id, sessionId: result.id)

        var totalItems = 0
        var userMessages = 0
        var agentMessages = 0
        var reasoningItems = 0
        var commandItems = 0
        var fileChangeItems = 0
        var unknownItems = 0
        var emptyAgentMessages = 0
        var emptyUserMessages = 0

        for turn in result.turns {
            for item in turn.items {
                totalItems += 1
                switch item {
                case .userMessage(let text):
                    userMessages += 1
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        emptyUserMessages += 1
                    }
                    viewModel.addUserMessage(content: text, images: [])

                case .agentMessage(let text):
                    agentMessages += 1
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        emptyAgentMessages += 1
                    }
                    viewModel.addAssistantMessage(text)

                case .reasoning(_, let text):
                    reasoningItems += 1
                    if !text.isEmpty {
                        viewModel.addAssistantSegments([
                            AssistantSegment(kind: .thought, text: text),
                        ])
                    }

                case .commandExecution(let itemId, let command, let output):
                    commandItems += 1
                    let title = command?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayTitle = (title?.isEmpty == false) ? title! : "Command execution"
                    let toolCall = ToolCallDisplay(
                        toolCallId: itemId,
                        title: displayTitle,
                        kind: "execute",
                        status: "completed",
                        output: output
                    )
                    viewModel.addAssistantSegments([
                        AssistantSegment(kind: .toolCall, text: displayTitle, toolCall: toolCall),
                    ])

                case .fileChange(let itemId, let path, let changeType, let diff):
                    fileChangeItems += 1
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
                    let kind = "edit"
                    let toolCall = ToolCallDisplay(
                        toolCallId: itemId,
                        title: displayTitle,
                        kind: kind,
                        status: "completed",
                        output: diff
                    )
                    viewModel.addAssistantSegments([
                        AssistantSegment(kind: .toolCall, text: displayTitle, toolCall: toolCall),
                    ])

                case .toolCall(let itemId, let title, let kind, let status, let output):
                    commandItems += 1
                    let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let toolCall = ToolCallDisplay(
                        toolCallId: itemId,
                        title: displayTitle.isEmpty ? "Tool call" : displayTitle,
                        kind: kind,
                        status: status ?? "completed",
                        output: output
                    )
                    viewModel.addAssistantSegments([
                        AssistantSegment(kind: .toolCall, text: displayTitle, toolCall: toolCall),
                    ])

                case .unknown(let type):
                    unknownItems += 1
                    appendClosure("Unknown Codex item type: \(type)")
                }
            }
        }

        appendClosure(
            "Codex thread history: turns=\(result.turns.count), items=\(totalItems), user=\(userMessages), agent=\(agentMessages), reasoning=\(reasoningItems), command=\(commandItems), file=\(fileChangeItems), unknown=\(unknownItems), emptyUser=\(emptyUserMessages), emptyAgent=\(emptyAgentMessages)"
        )

        // Save the loaded state to cache for offline access
        viewModel.saveChatState()
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
            self.sessionId = ""
            self.selectedSessionId = nil
            currentSessionViewModel?.resetChatState()
            Task { await sessionLogger?.endSession() }
        }

        removeSessionViewModel(for: sessionId)
        storage?.deleteSession(sessionId: sessionId, forServerId: id)
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
                    skills: skillNames
                )
                bumpSessionTimestamp(sessionId: sessionId)
                updateSessionTitleIfNeeded(with: prompt)
            } catch {
                appendClosure("Failed to send Codex prompt: \(error.localizedDescription)")
                failPendingTurn(formatPromptError(error))
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
        var params: [String: JSONValue] = ["approvalPolicy": .string(approvalPolicy)]
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

    private func startTurn(threadId: String, text: String, model: String?, effort: String?, skills: [String]?) async throws {
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

        let response = try await callCodex(method: "turn/start", params: .object(params))
        activeThreadId = threadId
        activeTurnId = response.result?.objectValue?["turn"]?.objectValue?["id"]?.stringValue
    }

    private func resumeThread(threadId: String) async throws -> CodexThreadResumeResult {
        let response = try await callCodex(
            method: "thread/resume",
            params: .object(["threadId": .string(threadId)])
        )
        guard let result = parseThreadResume(result: response.result) else {
            throw ACPServiceError.unsupportedMessage
        }
        activeThreadId = result.id
        activeTurnId = nil
        return result
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

    // MARK: - Codex Message Handling

    /// Handle Codex-specific messages (notifications from the backend).
    func handleCodexMessage(_ message: JSONRPCMessage) {
        switch message {
        case .notification(let notification):
            guard let params = notification.params?.objectValue else { return }
            let threadId = params["threadId"]?.stringValue
            if let activeThreadId, let threadId, threadId != activeThreadId { return }

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
                if let activeTurnId,
                   let turnId = params["turnId"]?.stringValue,
                   turnId != activeTurnId {
                    return
                }
                if let delta = params["delta"]?.stringValue {
                    currentSessionViewModel?.appendAssistantText(delta, kind: .message)
                }
            case "item/started":
                let turnId = params["turnId"]?.stringValue
                if let activeTurnId, let turnId, turnId != activeTurnId {
                    return
                }
                if let itemValue = params["item"] {
                    handleCodexItemEvent(itemValue, status: "in_progress", turnId: turnId)
                }
            case "item/completed":
                let turnId = params["turnId"]?.stringValue
                if let activeTurnId, let turnId, turnId != activeTurnId {
                    return
                }
                if let itemValue = params["item"] {
                    handleCodexItemEvent(itemValue, status: "completed", turnId: turnId)
                }
            case "turn/completed":
                let completedTurnId = params["turn"]?.objectValue?["id"]?.stringValue
                if let activeTurnId, let completedTurnId, completedTurnId != activeTurnId {
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
                if let serverId = selectedSessionId {
                    eventDelegate?.sessionDidReceiveStopReason("turn_completed", serverId: id, sessionId: serverId)
                }
            case "turn/started":
                if let turnId = params["turn"]?.objectValue?["id"]?.stringValue {
                    activeTurnId = turnId
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
            default:
                break
            }

        case .request(let request):
            switch request.method {
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                // Approval requests are handled by handleApprovalRequest from AppViewModel.
                break
            default:
                break
            }

        case .response, .error:
            break
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

        case .agentMessage, .userMessage, .unknown:
            break
        }
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

        return all
    }

    private func parseThreadResume(result: JSONValue?) -> CodexThreadResumeResult? {
        guard let object = result?.objectValue else { return nil }
        guard let thread = object["thread"]?.objectValue else { return nil }
        guard let id = thread["id"]?.stringValue, !id.isEmpty else { return nil }

        let preview = thread["preview"]?.stringValue
        let cwd = thread["cwd"]?.stringValue ?? object["cwd"]?.stringValue
        let createdAt = parseUnixDate(thread["createdAt"])

        var turns: [CodexThreadResumeResult.Turn] = []
        if case let .array(turnsArray)? = thread["turns"] {
            for turnValue in turnsArray {
                guard let turnObj = turnValue.objectValue else { continue }
                guard let turnId = turnObj["id"]?.stringValue else { continue }
                let status = turnObj["status"]?.stringValue

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

    private func parseThreadItem(_ value: JSONValue) -> CodexThreadResumeResult.Item? {
        guard let obj = value.objectValue else { return nil }
        guard let type = obj["type"]?.stringValue else { return nil }
        let itemId = obj["id"]?.stringValue
        let normalizedType = type.replacingOccurrences(of: "_", with: "").lowercased()

        switch normalizedType {
        case "usermessage":
            let text = extractTextContent(from: obj)
            return .userMessage(text)
        case "agentmessage", "assistantmessage":
            let directText = obj["text"]?.stringValue ?? ""
            let contentText = extractTextContent(from: obj)
            let text = directText.isEmpty ? contentText : directText
            return .agentMessage(text)
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
        if case let .object(outputObject)? = object["output"] {
            let nestedStdout = stringValue(from: outputObject["stdout"])
            let nestedStderr = stringValue(from: outputObject["stderr"])
            let nestedDirect = firstNonEmptyString(
                stringValue(from: outputObject["text"]),
                stringValue(from: outputObject["result"])
            )
            if !nestedDirect.isEmpty {
                return nestedDirect
            }
            if let nestedStdout, let nestedStderr, !nestedStdout.isEmpty || !nestedStderr.isEmpty {
                let combined = [nestedStdout, nestedStderr].filter { !$0.isEmpty }.joined(separator: "\n")
                return combined.isEmpty ? nil : combined
            }
        }

        let direct = firstNonEmptyString(
            stringValue(from: object["output"]),
            stringValue(from: object["result"]),
            stringValue(from: object["response"])
        )
        let stdout = stringValue(from: object["stdout"])
        let stderr = stringValue(from: object["stderr"])
        if !direct.isEmpty {
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
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "Tool call"
    }

    private func extractTextContent(from object: [String: JSONValue]) -> String {
        var textParts: [String] = []
        if case let .array(contentArray)? = object["content"] {
            for contentItem in contentArray {
                guard let contentObj = contentItem.objectValue else { continue }
                let type = contentObj["type"]?.stringValue?.lowercased()
                let isTextType = type == "text" || type == "input_text" || type == "output_text"
                if isTextType, let text = contentObj["text"]?.stringValue, !text.isEmpty {
                    textParts.append(text)
                }
            }
        }

        if !textParts.isEmpty {
            return textParts.joined(separator: "\n")
        }

        if let directText = object["text"]?.stringValue {
            return directText
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
