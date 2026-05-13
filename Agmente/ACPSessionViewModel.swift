import Foundation
import ACPClient
import ACP
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Delegate protocol for session cache operations.
/// Separates cache storage (owned by delegate) from cache logic (in ACPSessionViewModel).
@MainActor
protocol ACPSessionCacheDelegate: AnyObject {
    /// Save chat messages for a session.
    func saveMessages(_ messages: [ChatMessage], for serverId: UUID, sessionId: String)

    /// Load cached chat messages for a session.
    func loadMessages(for serverId: UUID, sessionId: String) -> [ChatMessage]?

    /// Save stop reason for a session.
    func saveStopReason(_ reason: String, for serverId: UUID, sessionId: String)

    /// Load cached stop reason for a session.
    func loadStopReason(for serverId: UUID, sessionId: String) -> String?

    /// Clear cache for a specific session.
    func clearCache(for serverId: UUID, sessionId: String)

    /// Clear all cache entries for a server.
    func clearCache(for serverId: UUID)

    /// Migrate cache from placeholder session ID to resolved session ID.
    func migrateCache(serverId: UUID, from placeholderId: String, to resolvedId: String)

    /// Check if there are cached messages for a session.
    func hasCachedMessages(serverId: UUID, sessionId: String) -> Bool

    /// Get formatted message preview for session list display.
    func getLastMessagePreview(for serverId: UUID, sessionId: String) -> String?

    /// Load chat from persistent storage (for agents without session/load support).
    func loadChatFromStorage(sessionId: String, serverId: UUID) -> [ChatMessage]

    /// Persist chat to storage if needed (for agents without session/load support).
    func persistChatToStorage(serverId: UUID, sessionId: String)
}

/// Delegate protocol for session events that require app-level handling.
/// Allows ACPSessionViewModel to notify AppViewModel about events without coupling.
@MainActor
protocol ACPSessionEventDelegate: AnyObject {
    /// Called when session mode changes.
    func sessionModeDidChange(_ modeId: String, serverId: UUID, sessionId: String)

    /// Called when stop reason is received and streaming should finish.
    func sessionDidReceiveStopReason(_ reason: String, serverId: UUID, sessionId: String)

    /// Called when session load completes and streaming should finish.
    func sessionLoadDidComplete(serverId: UUID, sessionId: String)
}

@MainActor
final class ACPSessionViewModel: ObservableObject {
    struct Dependencies {
        let getService: () -> ACPService?
        let append: (String) -> Void
        let logWire: (String, ACPWireMessage) -> Void
    }

    @Published private(set) var currentModeId: String?
    @Published private(set) var availableModes: [AgentModeOption] = []
    @Published private(set) var sessionConfigOptions: [ACPSessionConfigOption] = []
    @Published private(set) var availableCommands: [SessionCommand] = []
    @Published var promptText: String = ""
    @Published var selectedCommandName: String?
    @Published private(set) var attachedImages: [ImageAttachment] = []
    @Published private(set) var supportsImageAttachment: Bool = false
    @Published private(set) var chatMessages: [ChatMessage] = []
    @Published private(set) var stopReason: String = ""

    weak var cacheDelegate: ACPSessionCacheDelegate?
    weak var eventDelegate: ACPSessionEventDelegate?
    private let dependencies: Dependencies
    private let sessionUpdateHandler = ACPSessionUpdateHandler()
    private var streamingMessageId: UUID?
    private var currentServerId: UUID?
    private var currentSessionId: String?
    private var sessionModeCache: [UUID: [String: String]] = [:] // serverId -> sessionId -> currentModeId
    private var pendingPermissionRequests: [ACP.ID: (sessionId: String, toolCallId: String?)] = [:]
    private var pendingApprovalRequests: [JSONRPCID: String?] = [:]
    private var replayRecovery: ReplayRecoveryState?
    @Published var activeUserInputRequest: PendingUserInputRequest?
    private var sessionCommandsCache: [UUID: [String: [SessionCommand]]] = [:] // serverId -> sessionId -> available commands
    // Note: chatCache and stopReasonCache moved to AppViewModel (accessed via cacheDelegate)

    private struct ReplayRecoveryState {
        let serverId: UUID?
        let sessionId: String
        let epoch: UUID
        var bufferedUpdates: [ACP.Value?]
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func resetStreamingState() {
        streamingMessageId = nil
    }

    func restoreStreamingState(from messages: [ChatMessage]) {
        streamingMessageId = messages.last(where: { $0.isStreaming })?.id
    }

    func currentStreamingAssistantMessageId() -> UUID? {
        streamingMessageId
    }

    // MARK: - Image Attachments

    var canAttachMoreImages: Bool {
        supportsImageAttachment && attachedImages.count < ImageProcessor.maxAttachments
    }

    func setSupportsImageAttachment(_ supports: Bool) {
        supportsImageAttachment = supports
        if !supports {
            clearImageAttachments()
        }
    }

    func replaceAttachments(_ attachments: [ImageAttachment]) {
        attachedImages = attachments
    }

    @discardableResult
    func addImageAttachment(_ image: UIImage) -> Bool {
        guard canAttachMoreImages else {
            dependencies.append("Cannot attach more images (limit: \(ImageProcessor.maxAttachments))")
            return false
        }

        guard let attachment = ImageProcessor.processImage(image) else {
            dependencies.append("Failed to process image")
            return false
        }

        attachedImages.append(attachment)
        dependencies.append("Attached image (\(attachment.sizeDescription))")
        return true
    }

    func removeImageAttachment(_ id: UUID) {
        attachedImages.removeAll { $0.id == id }
    }

    func clearImageAttachments() {
        attachedImages.removeAll()
    }

    func setCurrentModeId(_ modeId: String?) {
        currentModeId = modeId
    }

    func setAvailableModes(_ modes: [AgentModeOption], currentModeId: String? = nil) {
        availableModes = modes
        if let currentModeId {
            self.currentModeId = currentModeId
        }
    }

    func applySessionConfigOptions(
        _ options: [ACPSessionConfigOption],
        serverId: UUID?,
        sessionId: String
    ) {
        sessionConfigOptions = options

        if let modeInfo = ACPSessionConfigOptionParser.modeInfo(from: options) {
            availableModes = modeInfo.availableModes
            if let modeId = modeInfo.currentModeId {
                currentModeId = modeId
                cacheCurrentMode(serverId: serverId, sessionId: sessionId)
            }
        }
    }

    func visibleConfigOptions() -> [ACPSessionConfigOption] {
        sessionConfigOptions.filter { !$0.isModeSelector }
    }

    func cacheCurrentMode(serverId: UUID?, sessionId: String) {
        guard let serverId, !sessionId.isEmpty else { return }
        var serverModes = sessionModeCache[serverId] ?? [:]
        if let modeId = currentModeId {
            serverModes[sessionId] = modeId
        } else {
            serverModes.removeValue(forKey: sessionId)
        }
        sessionModeCache[serverId] = serverModes
    }

    func cachedMode(for serverId: UUID, sessionId: String) -> String? {
        sessionModeCache[serverId]?[sessionId]
    }

    func migrateSessionModeCache(for serverId: UUID, from placeholderId: String, to resolvedId: String) {
        guard placeholderId != resolvedId else { return }
        if var serverModes = sessionModeCache[serverId],
           let mode = serverModes[placeholderId],
           serverModes[resolvedId] == nil {
            serverModes[resolvedId] = mode
            sessionModeCache[serverId] = serverModes
        }
    }

    // MARK: - Commands

    func resetCommands() {
        availableCommands = []
        selectedCommandName = nil
    }

    func handleAvailableCommandsUpdate(
        _ commands: [SessionCommand],
        serverId: UUID?,
        sessionId: String
    ) {
        availableCommands = commands.map { cmd in
            SessionCommand(id: cmd.id, name: cmd.name, description: cmd.description, inputHint: cmd.inputHint)
        }
        cacheAvailableCommands(serverId: serverId, sessionId: sessionId)
        if let selectedCommandName,
           !availableCommands.contains(where: { $0.name == selectedCommandName }) {
            self.selectedCommandName = nil
        }
    }

    func restoreAvailableCommands(for serverId: UUID, sessionId: String, isNew: Bool) {
        if let cached = sessionCommandsCache[serverId]?[sessionId] {
            availableCommands = cached
        } else if isNew {
            availableCommands = []
        }
        selectedCommandName = nil
    }

    func migrateSessionCommandsCache(for serverId: UUID, from placeholderId: String, to resolvedId: String) {
        guard placeholderId != resolvedId else { return }
        if var serverCommands = sessionCommandsCache[serverId],
           let commands = serverCommands[placeholderId],
           serverCommands[resolvedId] == nil {
            serverCommands[resolvedId] = commands
            sessionCommandsCache[serverId] = serverCommands
        }
    }

    func removeCommands(for serverId: UUID, sessionId: String) {
        var serverCommands = sessionCommandsCache[serverId] ?? [:]
        serverCommands.removeValue(forKey: sessionId)
        sessionCommandsCache[serverId] = serverCommands
    }

    func removeServerCommandsCache(for serverId: UUID) {
        sessionCommandsCache.removeValue(forKey: serverId)
    }

    private func cacheAvailableCommands(serverId: UUID?, sessionId: String) {
        guard let serverId, !sessionId.isEmpty else { return }
        var serverCommands = sessionCommandsCache[serverId] ?? [:]
        serverCommands[sessionId] = availableCommands
        sessionCommandsCache[serverId] = serverCommands
    }

    func sendSetMode(
        _ modeId: String,
        sessionId: String,
        serverId: UUID?
    ) {
        guard let service = dependencies.getService() else {
            dependencies.append("Not connected")
            return
        }
        guard !sessionId.isEmpty else {
            dependencies.append("No active session")
            return
        }

        Task { @MainActor in
            do {
                if let modeOption = sessionConfigOptions.first(where: { $0.isModeSelector }) {
                    let payload = ACPSessionSetConfigOptionPayload(
                        sessionId: sessionId,
                        configId: modeOption.id,
                        value: .string(modeId)
                    )
                    _ = try await service.setSessionConfigOption(payload)
                } else {
                    let payload = ACPSessionSetModePayload(sessionId: sessionId, modeId: modeId)
                    _ = try await service.setSessionMode(payload)
                }
                setCurrentModeId(modeId)
                cacheCurrentMode(serverId: serverId, sessionId: sessionId)
                dependencies.append("Set mode to: \(modeId)")
            } catch {
                dependencies.append("Failed to set mode: \(error)")
            }
        }
    }

    func sendSetConfigOption(
        configId: String,
        value: ACPSessionConfigOptionValue,
        sessionId: String,
        serverId: UUID?
    ) {
        guard let service = dependencies.getService() else {
            dependencies.append("Not connected")
            return
        }
        guard !sessionId.isEmpty else {
            dependencies.append("No active session")
            return
        }

        let payload = ACPSessionSetConfigOptionPayload(
            sessionId: sessionId,
            configId: configId,
            value: value
        )

        Task { @MainActor in
            do {
                _ = try await service.setSessionConfigOption(payload)
                if let index = sessionConfigOptions.firstIndex(where: { $0.id == configId }) {
                    let existing = sessionConfigOptions[index]
                    sessionConfigOptions[index] = ACPSessionConfigOption(
                        id: existing.id,
                        name: existing.name,
                        description: existing.description,
                        category: existing.category,
                        kind: existing.kind,
                        currentValue: value
                    )
                    applySessionConfigOptions(sessionConfigOptions, serverId: serverId, sessionId: sessionId)
                }
                dependencies.append("Updated \(configId)")
            } catch {
                dependencies.append("Failed to update \(configId): \(error)")
            }
        }
    }

    func handleChatUpdate(
        _ params: ACP.Value?,
        activeSessionId: String,
        serverId: UUID?
    ) {
        guard let updateSessionId = ACPSessionUpdateHandler.sessionId(from: params),
              updateSessionId == activeSessionId else { return }

        if replayRecovery?.sessionId == activeSessionId {
            replayRecovery?.bufferedUpdates.append(params)
            return
        }

        let events = sessionUpdateHandler.handle(params: params, activeSessionId: activeSessionId)
        for event in events {
            applySessionUpdateEvent(event, serverId: serverId, sessionId: activeSessionId, mergeReplay: false)
        }
    }

    func beginReplayRecovery(serverId: UUID?, sessionId: String) {
        replayRecovery = ReplayRecoveryState(
            serverId: serverId,
            sessionId: sessionId,
            epoch: UUID(),
            bufferedUpdates: []
        )
    }

    func cancelReplayRecovery(sessionId: String) {
        guard replayRecovery?.sessionId == sessionId else { return }
        replayRecovery = nil
    }

    func completeReplayRecovery(serverId: UUID?, sessionId: String) {
        guard let recovery = replayRecovery, recovery.sessionId == sessionId else { return }
        replayRecovery = nil

        for params in recovery.bufferedUpdates {
            let events = sessionUpdateHandler.handle(params: params, activeSessionId: sessionId)
            for event in events {
                applySessionUpdateEvent(
                    event,
                    serverId: serverId ?? recovery.serverId,
                    sessionId: sessionId,
                    mergeReplay: true
                )
            }
        }

        finishReplayStreamingIfSettled()
        saveChatState()
    }

    func isReplayingRecovery(sessionId: String) -> Bool {
        replayRecovery?.sessionId == sessionId
    }

    /// Respond to a pending permission request with the user's choice.
    func sendPermissionResponse(requestId: ACP.ID, optionId: String) {
        guard let service = dependencies.getService() else {
            dependencies.append("Not connected")
            return
        }
        if let pending = pendingPermissionRequests.removeValue(forKey: requestId) {
            clearPermissionOptionsForToolCall(pending.toolCallId)
        }

        let response = ACPMessageBuilder.permissionResponseSelected(
            requestId: requestId,
            optionId: optionId
        )

        Task { @MainActor in
            do {
                try await service.sendMessage(response)
                dependencies.logWire("→", response)
                dependencies.append("Permission response: selected \(optionId)")
            } catch {
                dependencies.append("Failed to send permission response: \(error)")
            }
        }
    }

    /// Cancel all pending permission requests for a session.
    func cancelPendingPermissionRequests(for sessionIdToCancel: String) {
        guard let service = dependencies.getService() else { return }

        let requestsToCancel = pendingPermissionRequests.filter { $0.value.sessionId == sessionIdToCancel }
        for (requestId, pending) in requestsToCancel {
            pendingPermissionRequests.removeValue(forKey: requestId)
            clearPermissionOptionsForToolCall(pending.toolCallId)

            let response = ACPMessageBuilder.permissionResponseCancelled(requestId: requestId)

            Task { @MainActor in
                do {
                    try await service.sendMessage(response)
                    dependencies.logWire("→", response)
                } catch {
                    dependencies.append("Failed to send cancelled permission response: \(error)")
                }
            }
        }
    }

    /// Handle an incoming permission request from the agent.
    func handlePermissionRequest(_ request: ACP.AnyRequest) {
        guard let parsed = ACPPermissionRequestParser.parse(params: request.params) else {
            dependencies.append("Invalid permission request: missing params")
            return
        }

        let requestSessionId = parsed.sessionId ?? ""
        let toolCallId = parsed.toolCallId
        let toolTitle = parsed.toolCallTitle
        let toolKind = parsed.toolCallKind
        let requestId = request.id

        let options = parsed.options
        pendingPermissionRequests[requestId] = (sessionId: requestSessionId, toolCallId: toolCallId)

        updateToolCallWithPermission(
            toolCallId: toolCallId,
            title: toolTitle,
            kind: toolKind,
            options: options,
            requestId: requestId
        )

        dependencies.append("Permission requested for: \(toolTitle) (options: \(options.map { $0.name }.joined(separator: ", ")))")
    }

    func handleSessionUpdateEvents(
        _ params: ACP.Value?,
        activeSessionId: String,
        serverId: UUID?
    ) {
        handleChatUpdate(params, activeSessionId: activeSessionId, serverId: serverId)
    }

    /// Handle fs/read_text_file request from the agent.
    /// iOS client cannot access the agent's remote filesystem, so we return an error.
    func handleFSReadRequest(_ request: ACP.AnyRequest) {
        let path = request.params.objectValue?["path"]?.stringValue ?? "unknown"
        dependencies.append("FS read requested: \(path) - not supported on iOS client")
        sendErrorResponse(
            to: request.id,
            code: -32001,
            message: "Filesystem access not available from iOS client. The file '\(path)' cannot be read."
        )
    }

    /// Handle fs/write_text_file request from the agent.
    func handleFSWriteRequest(_ request: ACP.AnyRequest) {
        let path = request.params.objectValue?["path"]?.stringValue ?? "unknown"
        dependencies.append("FS write requested: \(path) - not supported on iOS client")
        sendErrorResponse(
            to: request.id,
            code: -32001,
            message: "Filesystem access not available from iOS client. The file '\(path)' cannot be written."
        )
    }

    /// Handle terminal requests from the agent.
    /// iOS client cannot provide terminal access, so we return an error.
    func handleTerminalRequest(_ request: ACP.AnyRequest) {
        dependencies.append("Terminal request: \(request.method) - not supported on iOS client")
        sendErrorResponse(
            to: request.id,
            code: -32001,
            message: "Terminal access not available from iOS client."
        )
    }

    /// Send an error response to a request.
    func sendErrorResponse(to requestId: ACP.ID, code: Int, message: String) {
        guard let service = dependencies.getService() else { return }

        let errorResponse = ACPMessageBuilder.errorResponse(requestId: requestId, code: code, message: message)

        Task { @MainActor in
            do {
                try await service.sendMessage(errorResponse)
                dependencies.logWire("→", errorResponse)
            } catch {
                dependencies.append("Failed to send error response: \(error)")
            }
        }
    }

    private func updateToolCallWithPermission(
        toolCallId: String?,
        title: String,
        kind: String?,
        options: [ACPPermissionOption],
        requestId: ACP.ID
    ) {
        if let toolCallId,
           let messageIndex = chatMessages.firstIndex(where: { message in
               message.role == .assistant && message.segments.contains(where: { segment in
                   segment.kind == .toolCall && segment.toolCall?.toolCallId == toolCallId
               })
           }),
           let existingIndex = chatMessages[messageIndex].segments.firstIndex(where: { segment in
               segment.kind == .toolCall && segment.toolCall?.toolCallId == toolCallId
           }) {
            chatMessages[messageIndex].segments[existingIndex].toolCall?.permissionOptions = options
            chatMessages[messageIndex].segments[existingIndex].toolCall?.acpPermissionRequestId = requestId
            chatMessages[messageIndex].segments[existingIndex].toolCall?.status = "awaiting_permission"
            rebuildAssistantContent(at: messageIndex)
            saveChatState()
            return
        }

        let index = ensureStreamingAssistantMessage()
        guard index >= 0, index < chatMessages.count else { return }

        if let toolCallId,
           let existingIndex = chatMessages[index].segments.firstIndex(where: { segment in
               segment.kind == .toolCall && segment.toolCall?.toolCallId == toolCallId
           }) {
            chatMessages[index].segments[existingIndex].toolCall?.permissionOptions = options
            chatMessages[index].segments[existingIndex].toolCall?.acpPermissionRequestId = requestId
            chatMessages[index].segments[existingIndex].toolCall?.status = "awaiting_permission"
        } else {
            var toolCall = ToolCallDisplay(toolCallId: toolCallId, title: title, kind: kind, status: "awaiting_permission")
            toolCall.permissionOptions = options
            toolCall.acpPermissionRequestId = requestId
            chatMessages[index].segments.append(AssistantSegment(kind: .toolCall, text: title, toolCall: toolCall))
        }

        rebuildAssistantContent(at: index)
        saveChatState()
    }

    func updateToolCallWithApproval(
        toolCallId: String?,
        title: String,
        kind: String?,
        requestId: JSONRPCID,
        approvalKind: String?,
        reason: String?,
        command: String?,
        cwd: String?
    ) {
        pendingApprovalRequests[requestId] = toolCallId

        if let toolCallId,
           let messageIndex = chatMessages.firstIndex(where: { message in
               message.role == .assistant && message.segments.contains(where: { segment in
                   segment.kind == .toolCall && segment.toolCall?.toolCallId == toolCallId
               })
           }),
           let existingIndex = chatMessages[messageIndex].segments.firstIndex(where: { segment in
               segment.kind == .toolCall && segment.toolCall?.toolCallId == toolCallId
           }) {
            var toolCall = chatMessages[messageIndex].segments[existingIndex].toolCall
            toolCall?.status = "awaiting_permission"
            toolCall?.approvalRequestId = requestId
            toolCall?.approvalKind = approvalKind
            toolCall?.approvalReason = reason
            toolCall?.approvalCommand = command
            toolCall?.approvalCwd = cwd
            if let toolCall, !toolCall.title.isEmpty {
                chatMessages[messageIndex].segments[existingIndex].toolCall = toolCall
            } else if let toolCall {
                var updatedToolCall = toolCall
                updatedToolCall.title = title
                chatMessages[messageIndex].segments[existingIndex].toolCall = updatedToolCall
                chatMessages[messageIndex].segments[existingIndex].text = title
            }
            rebuildAssistantContent(at: messageIndex)
            saveChatState()
            return
        }

        let index = ensureStreamingAssistantMessage()
        guard index >= 0, index < chatMessages.count else { return }

        if let toolCallId,
           let existingIndex = chatMessages[index].segments.firstIndex(where: { segment in
               segment.kind == .toolCall && segment.toolCall?.toolCallId == toolCallId
           }) {
            var toolCall = chatMessages[index].segments[existingIndex].toolCall
            toolCall?.status = "awaiting_permission"
            toolCall?.approvalRequestId = requestId
            toolCall?.approvalKind = approvalKind
            toolCall?.approvalReason = reason
            toolCall?.approvalCommand = command
            toolCall?.approvalCwd = cwd
            chatMessages[index].segments[existingIndex].toolCall = toolCall
        } else {
            var toolCall = ToolCallDisplay(toolCallId: toolCallId, title: title, kind: kind, status: "awaiting_permission")
            toolCall.approvalRequestId = requestId
            toolCall.approvalKind = approvalKind
            toolCall.approvalReason = reason
            toolCall.approvalCommand = command
            toolCall.approvalCwd = cwd
            chatMessages[index].segments.append(AssistantSegment(kind: .toolCall, text: title, toolCall: toolCall))
        }

        rebuildAssistantContent(at: index)
        saveChatState()
    }

    func clearApprovalRequest(_ requestId: JSONRPCID) {
        let toolCallId = pendingApprovalRequests.removeValue(forKey: requestId) ?? nil
        clearApprovalForToolCall(toolCallId)
    }

    private func clearPermissionOptionsForToolCall(_ toolCallId: String?) {
        var updatedIndexes: [Int] = []

        for msgIndex in chatMessages.indices {
            guard chatMessages[msgIndex].role == .assistant else { continue }
            for segIndex in chatMessages[msgIndex].segments.indices {
                let segment = chatMessages[msgIndex].segments[segIndex]
                if segment.kind == .toolCall,
                   (toolCallId == nil || segment.toolCall?.toolCallId == toolCallId),
                   segment.toolCall?.permissionOptions != nil {
                    chatMessages[msgIndex].segments[segIndex].toolCall?.permissionOptions = nil
                    chatMessages[msgIndex].segments[segIndex].toolCall?.acpPermissionRequestId = nil
                    if chatMessages[msgIndex].segments[segIndex].toolCall?.status == "awaiting_permission" {
                        chatMessages[msgIndex].segments[segIndex].toolCall?.status = "pending"
                    }
                    updatedIndexes.append(msgIndex)
                }
            }
        }

        guard !updatedIndexes.isEmpty else { return }
        for index in Set(updatedIndexes) {
            rebuildAssistantContent(at: index)
        }
        saveChatState()
    }

    private func clearApprovalForToolCall(_ toolCallId: String?) {
        var updatedIndexes: [Int] = []

        for msgIndex in chatMessages.indices {
            guard chatMessages[msgIndex].role == .assistant else { continue }
            for segIndex in chatMessages[msgIndex].segments.indices {
                guard chatMessages[msgIndex].segments[segIndex].kind == .toolCall else { continue }
                guard toolCallId == nil || chatMessages[msgIndex].segments[segIndex].toolCall?.toolCallId == toolCallId else { continue }
                guard chatMessages[msgIndex].segments[segIndex].toolCall?.approvalRequestId != nil else { continue }

                if chatMessages[msgIndex].segments[segIndex].toolCall?.status == "awaiting_permission" {
                    chatMessages[msgIndex].segments[segIndex].toolCall?.status = "pending"
                }
                chatMessages[msgIndex].segments[segIndex].toolCall?.approvalRequestId = nil
                chatMessages[msgIndex].segments[segIndex].toolCall?.approvalKind = nil
                chatMessages[msgIndex].segments[segIndex].toolCall?.approvalReason = nil
                chatMessages[msgIndex].segments[segIndex].toolCall?.approvalCommand = nil
                chatMessages[msgIndex].segments[segIndex].toolCall?.approvalCwd = nil
                updatedIndexes.append(msgIndex)
            }
        }

        guard !updatedIndexes.isEmpty else { return }
        for index in Set(updatedIndexes) {
            rebuildAssistantContent(at: index)
        }
        saveChatState()
    }

    private func applySessionUpdateEvent(
        _ event: ACPSessionUpdateEvent,
        serverId: UUID?,
        sessionId: String,
        mergeReplay: Bool
    ) {
        switch event {
        case .agentThought(let text):
            appendAssistantText(text, kind: .thought, mergeReplay: mergeReplay)

        case .userMessage(let text):
            appendUserChunk(text, mergeReplay: mergeReplay)

        case .agentMessage(let text):
            appendAssistantText(text, kind: .message, mergeReplay: mergeReplay)

        case .toolCall(let info):
            appendToolCall(
                toolCallId: info.toolCallId,
                title: info.title,
                kind: info.kind,
                status: info.status,
                mergeReplay: mergeReplay
            )

        case .toolCallUpdate(let update):
            applyToolCallUpdate(update, mergeReplay: mergeReplay)

        case .modeChange(let modeId):
            currentModeId = modeId
            cacheCurrentMode(serverId: serverId, sessionId: sessionId)
            // Notify delegate about mode change
            if let serverId = serverId {
                eventDelegate?.sessionModeDidChange(modeId, serverId: serverId, sessionId: sessionId)
            }

        case .configOptionsUpdate(let options):
            applySessionConfigOptions(options, serverId: serverId, sessionId: sessionId)
            dependencies.append("Config options updated (\(options.count))")

        case .availableCommandsUpdate(let commands):
            handleAvailableCommandsUpdate(
                commands,
                serverId: serverId,
                sessionId: sessionId
            )
            dependencies.append("Available commands updated (\(commands.count))")
        }
    }

    private func applyToolCallUpdate(_ update: ACPToolCallUpdate, mergeReplay: Bool = false) {
        guard !chatMessages.isEmpty else { return }
        let index = mergeReplay ? ensureReplayAssistantMessage() : ensureStreamingAssistantMessage()

        var targetIndex: Int?
        var messageIndex = index

        if mergeReplay,
           let toolCallId = update.toolCallId,
           let existing = findToolCallSegment(toolCallId: toolCallId) {
            messageIndex = existing.messageIndex
            targetIndex = existing.segmentIndex
        } else if let toolCallId = update.toolCallId,
                  let existingIndex = chatMessages[index].segments.firstIndex(where: { segment in
                      segment.kind == .toolCall && segment.toolCall?.toolCallId == toolCallId
                  }) {
            targetIndex = existingIndex
        } else if let toolCallId = update.toolCallId, let title = update.title, !title.isEmpty {
            let display = ToolCallDisplay(toolCallId: toolCallId, title: title, kind: update.kind, status: update.status)
            chatMessages[messageIndex].segments.append(AssistantSegment(kind: .toolCall, text: title, toolCall: display))
            targetIndex = chatMessages[messageIndex].segments.indices.last
        } else if let fallbackIndex = chatMessages[messageIndex].segments.lastIndex(where: { $0.kind == .toolCall }) {
            let incomingTitle = update.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let incomingKind = update.kind?.trimmingCharacters(in: .whitespacesAndNewlines)
            let existingTitle = chatMessages[messageIndex].segments[fallbackIndex].toolCall?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let existingKind = chatMessages[messageIndex].segments[fallbackIndex].toolCall?.kind?.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleDiffers = !incomingTitle.isEmpty && incomingTitle != existingTitle
            let kindDiffers = incomingKind != nil && incomingKind != existingKind

            if titleDiffers || kindDiffers {
                if !incomingTitle.isEmpty {
                    let display = ToolCallDisplay(toolCallId: update.toolCallId, title: incomingTitle, kind: update.kind, status: update.status)
                    chatMessages[messageIndex].segments.append(AssistantSegment(kind: .toolCall, text: incomingTitle, toolCall: display))
                    targetIndex = chatMessages[messageIndex].segments.indices.last
                }
            } else {
                targetIndex = fallbackIndex
            }
        } else if let title = update.title, !title.isEmpty {
            let display = ToolCallDisplay(toolCallId: update.toolCallId, title: title, kind: update.kind, status: update.status)
            chatMessages[messageIndex].segments.append(AssistantSegment(kind: .toolCall, text: title, toolCall: display))
            targetIndex = chatMessages[messageIndex].segments.indices.last
        }

        guard let resolvedIndex = targetIndex else { return }

        if var toolCall = chatMessages[messageIndex].segments[resolvedIndex].toolCall {
            toolCall.status = update.status ?? toolCall.status
            toolCall.kind = update.kind ?? toolCall.kind
            toolCall.title = update.title ?? toolCall.title
            chatMessages[messageIndex].segments[resolvedIndex].toolCall = toolCall
            if let title = update.title, !title.isEmpty {
                chatMessages[messageIndex].segments[resolvedIndex].text = title
            }
        }

        if let output = update.output {
            chatMessages[messageIndex].segments[resolvedIndex].toolCall?.output = output
        }

        rebuildAssistantContent(at: messageIndex)
        saveChatState()
    }

    private func appendUserChunk(_ text: String, mergeReplay: Bool = false) {
        guard !text.isEmpty else { return }

        let sanitized = ChatMessage.sanitizedUserContent(text)
        let didStrip = sanitized != text

        if mergeReplay, replayUserChunkAlreadyPresent(sanitized) {
            return
        }

        if streamingMessageId != nil {
            if let streamingIndex = chatMessages.firstIndex(where: { $0.id == streamingMessageId }),
               streamingIndex > 0,
               chatMessages[streamingIndex - 1].role == .user,
               chatMessages[streamingIndex - 1].content.contains(text) {
                return
            }
            finishStreamingMessage()
        }

        if let last = chatMessages.indices.last, chatMessages[last].role == .user {
            if didStrip {
                chatMessages[last].content = sanitized
            } else {
                chatMessages[last].content.append(text)
            }
        } else {
            let content = didStrip ? sanitized : text
            chatMessages.append(ChatMessage(role: .user, content: content, isStreaming: false))
        }
        saveChatState()
    }

    func appendAssistantText(_ text: String, kind: AssistantSegment.Kind, mergeReplay: Bool = false) {
        guard !text.isEmpty else { return }
        let index = mergeReplay ? ensureReplayAssistantMessage() : ensureStreamingAssistantMessage()

        if kind == .message, chatMessages[index].segments.isEmpty {
            let existing = chatMessages[index].content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !existing.isEmpty {
                // Resume snapshots can restore plain assistant content without segments.
                // Seed a message segment first so subsequent deltas append instead of replacing content.
                chatMessages[index].segments.append(AssistantSegment(kind: .message, text: chatMessages[index].content))
            }
        }

        if let lastIndex = chatMessages[index].segments.indices.last,
           chatMessages[index].segments[lastIndex].kind == kind,
           chatMessages[index].segments[lastIndex].toolCall == nil {
            let lastText = chatMessages[index].segments[lastIndex].text
            if lastText.hasSuffix("characters)") {
                chatMessages[index].segments.append(AssistantSegment(kind: kind, text: text))
            } else if mergeReplay {
                appendReplayText(text, toSegmentAt: lastIndex, messageIndex: index)
            } else {
                chatMessages[index].segments[lastIndex].text.append(text)
            }
        } else if mergeReplay,
                  let existingIndex = chatMessages[index].segments.lastIndex(where: { $0.kind == kind && $0.toolCall == nil }),
                  replayTextAlreadyPresent(text, in: chatMessages[index].segments[existingIndex].text) {
            return
        } else {
            chatMessages[index].segments.append(AssistantSegment(kind: kind, text: text))
        }
        rebuildAssistantContent(at: index)
        saveChatState()
    }

    func addAssistantSegments(_ segments: [AssistantSegment]) {
        guard !segments.isEmpty else { return }
        let message = ChatMessage(role: .assistant, content: "", isStreaming: false, segments: segments)
        chatMessages.append(message)
        let index = chatMessages.indices.last ?? 0
        rebuildAssistantContent(at: index)
        saveChatState()
    }

    /// Finalizes a plan segment with the complete text (used on item/completed).
    func completePlanItem(id: String?, text: String) {
        let index = ensureStreamingAssistantMessage()
        // Replace existing plan segment or append new one
        if let lastIndex = chatMessages[index].segments.indices.last,
           chatMessages[index].segments[lastIndex].kind == .plan {
            chatMessages[index].segments[lastIndex].text = text
        } else {
            chatMessages[index].segments.append(AssistantSegment(kind: .plan, text: text))
        }
        rebuildAssistantContent(at: index)
        saveChatState()
    }

    /// Stores a pending user input request from the server, presented as a sheet.
    func addUserInputRequest(requestId: JSONRPCID, questions: [UserInputQuestion]) {
        let request = PendingUserInputRequest(requestId: requestId, questions: questions)
        activeUserInputRequest = request
    }

    func upsertToolCallFromAppServer(
        toolCallId: String?,
        title: String?,
        kind: String?,
        status: String?,
        output: String?
    ) {
        let update = ACPToolCallUpdate(
            toolCallId: toolCallId,
            status: status,
            title: title,
            kind: kind,
            output: output
        )
        applyToolCallUpdate(update)
    }

    private func appendToolCall(toolCallId: String?, title: String, kind: String?, status: String, mergeReplay: Bool = false) {
        let index = mergeReplay ? ensureReplayAssistantMessage() : ensureStreamingAssistantMessage()
        var messageIndex = index

        let existingLocation: (messageIndex: Int, segmentIndex: Int)?
        if mergeReplay, let toolCallId {
            existingLocation = findToolCallSegment(toolCallId: toolCallId)
        } else if let toolCallId,
                  let existingIndex = chatMessages[index].segments.firstIndex(where: { $0.toolCall?.toolCallId == toolCallId }) {
            existingLocation = (index, existingIndex)
        } else if mergeReplay {
            existingLocation = findReplayToolCall(title: title, kind: kind, preferredMessageIndex: index)
        } else {
            existingLocation = nil
        }

        if let existingLocation {
            messageIndex = existingLocation.messageIndex
            var existingSegment = chatMessages[messageIndex].segments[existingLocation.segmentIndex]
            if var existingToolCall = existingSegment.toolCall {
                if !title.isEmpty {
                    existingToolCall.title = title
                }
                if let kind = kind, !kind.isEmpty {
                    existingToolCall.kind = kind
                }
                existingToolCall.status = status
                existingSegment.toolCall = existingToolCall

                let summary: String
                if let kind = existingToolCall.kind, !kind.isEmpty {
                    summary = "[\(kind)] \(existingToolCall.title)"
                } else {
                    summary = existingToolCall.title
                }
                existingSegment.text = summary
                chatMessages[messageIndex].segments[existingLocation.segmentIndex] = existingSegment

                if status == "in_progress" || status == "pending" {
                    chatMessages[messageIndex].isStreaming = true
                }

                rebuildAssistantContent(at: messageIndex)
                saveChatState()
                return
            }
        }

        let summary: String
        if let kind = kind {
            summary = "[\(kind)] \(title)"
        } else {
            summary = title
        }
        let toolCall = ToolCallDisplay(toolCallId: toolCallId, title: title, kind: kind, status: status)
        chatMessages[messageIndex].segments.append(AssistantSegment(kind: .toolCall, text: summary, toolCall: toolCall))

        if status == "in_progress" || status == "pending" {
            chatMessages[messageIndex].isStreaming = true
        }

        rebuildAssistantContent(at: messageIndex)
        saveChatState()
    }

    private func ensureReplayAssistantMessage() -> Int {
        if let streamingId = streamingMessageId,
           let index = chatMessages.firstIndex(where: { $0.id == streamingId && $0.role == .assistant }) {
            return index
        }
        if let index = chatMessages.indices.last(where: { chatMessages[$0].role == .assistant }) {
            streamingMessageId = chatMessages[index].id
            return index
        }
        return ensureStreamingAssistantMessage()
    }

    private func findToolCallSegment(toolCallId: String) -> (messageIndex: Int, segmentIndex: Int)? {
        for messageIndex in chatMessages.indices {
            guard chatMessages[messageIndex].role == .assistant else { continue }
            if let segmentIndex = chatMessages[messageIndex].segments.firstIndex(where: { $0.toolCall?.toolCallId == toolCallId }) {
                return (messageIndex, segmentIndex)
            }
        }
        return nil
    }

    private func findReplayToolCall(title: String, kind: String?, preferredMessageIndex: Int) -> (messageIndex: Int, segmentIndex: Int)? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        func matches(_ toolCall: ToolCallDisplay?) -> Bool {
            guard let toolCall else { return false }
            let existingTitle = toolCall.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let existingKind = toolCall.kind?.trimmingCharacters(in: .whitespacesAndNewlines)
            return existingTitle == trimmedTitle && (trimmedKind == nil || existingKind == trimmedKind)
        }

        if chatMessages.indices.contains(preferredMessageIndex),
           let segmentIndex = chatMessages[preferredMessageIndex].segments.firstIndex(where: { matches($0.toolCall) }) {
            return (preferredMessageIndex, segmentIndex)
        }

        for messageIndex in chatMessages.indices.reversed() {
            guard chatMessages[messageIndex].role == .assistant else { continue }
            if let segmentIndex = chatMessages[messageIndex].segments.firstIndex(where: { matches($0.toolCall) }) {
                return (messageIndex, segmentIndex)
            }
        }
        return nil
    }

    private func replayUserChunkAlreadyPresent(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return chatMessages.contains { message in
            guard message.role == .user else { return false }
            let existing = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return existing == trimmed || existing.contains(trimmed)
        }
    }

    private func replayTextAlreadyPresent(_ incoming: String, in existing: String) -> Bool {
        guard !incoming.isEmpty else { return true }
        return existing == incoming || existing.hasSuffix(incoming) || existing.contains(incoming)
    }

    private func appendReplayText(_ incoming: String, toSegmentAt segmentIndex: Int, messageIndex: Int) {
        let existing = chatMessages[messageIndex].segments[segmentIndex].text
        guard !replayTextAlreadyPresent(incoming, in: existing) else { return }
        if incoming.hasPrefix(existing) {
            chatMessages[messageIndex].segments[segmentIndex].text = incoming
            return
        }

        let overlap = suffixPrefixOverlap(existing, incoming)
        let start = incoming.index(incoming.startIndex, offsetBy: overlap)
        chatMessages[messageIndex].segments[segmentIndex].text.append(String(incoming[start...]))
    }

    private func suffixPrefixOverlap(_ existing: String, _ incoming: String) -> Int {
        let maxLength = min(existing.count, incoming.count)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) {
            let existingSuffix = existing.suffix(length)
            let incomingPrefix = incoming.prefix(length)
            if existingSuffix == incomingPrefix {
                return length
            }
        }
        return 0
    }

    private func finishReplayStreamingIfSettled() {
        guard let streamingId = streamingMessageId,
              let index = chatMessages.firstIndex(where: { $0.id == streamingId && $0.role == .assistant }) else {
            return
        }

        let hasActiveTool = chatMessages[index].segments.contains { segment in
            guard segment.kind == .toolCall else { return false }
            let status = segment.toolCall?.status?.lowercased()
            return status == "pending" || status == "in_progress" || status == "awaiting_permission"
        }
        if !hasActiveTool {
            finishStreamingMessage()
        }
    }

    func ensureStreamingAssistantMessage() -> Int {
        if let streamingId = streamingMessageId,
           let index = chatMessages.firstIndex(where: { $0.id == streamingId && $0.role == .assistant }) {
            // If a newer user prompt exists after the current streaming assistant row,
            // this pointer is stale (commonly after reopen/merge). Start a fresh
            // streaming assistant row at the tail so deltas attach to the latest turn.
            if let lastUserIndex = chatMessages.lastIndex(where: { $0.role == .user }),
               lastUserIndex > index {
                chatMessages[index].isStreaming = false
            } else {
                return index
            }
        }

        let message = ChatMessage(role: .assistant, content: "", isStreaming: true)
        chatMessages.append(message)
        streamingMessageId = message.id
        return chatMessages.indices.last ?? 0
    }

    /// Rebinds streaming state to a specific assistant message.
    /// If `messageId` is nil, all assistant messages are marked non-streaming.
    func bindStreamingAssistantMessage(to messageId: UUID?) {
        var didChange = false
        for index in chatMessages.indices {
            guard chatMessages[index].role == .assistant else { continue }
            let shouldStream = (chatMessages[index].id == messageId)
            if chatMessages[index].isStreaming != shouldStream {
                chatMessages[index].isStreaming = shouldStream
                didChange = true
            }
        }
        if streamingMessageId != messageId {
            streamingMessageId = messageId
            didChange = true
        }
        if didChange {
            saveChatState()
        }
    }

    func rebuildAssistantContent(at index: Int) {
        guard chatMessages.indices.contains(index) else { return }
        let segments = chatMessages[index].segments
        guard !segments.isEmpty else { return }

        let lines = segments.compactMap { segment -> String? in
            switch segment.kind {
            case .message, .thought:
                return segment.text
            case .toolCall:
                let displayTitle: String
                if let toolCall = segment.toolCall, let kind = toolCall.kind, !kind.isEmpty {
                    displayTitle = "[\(kind)] \(toolCall.title)"
                } else {
                    displayTitle = segment.toolCall?.title ?? segment.text
                }
                let displayContent = displayTitle
                guard !displayContent.isEmpty else { return nil }
                if let status = segment.toolCall?.status, !status.isEmpty {
                    return "Tool call: \(displayContent) (\(status))"
                }
                return "Tool call: \(displayContent)"
            case .plan:
                return segment.text
            }
        }

        chatMessages[index].content = lines.joined(separator: "\n")
    }

    func finishStreamingMessage() {
        guard let streamingId = streamingMessageId, let index = chatMessages.firstIndex(where: { $0.id == streamingId }) else {
            streamingMessageId = nil
            saveChatState()
            return
        }
        chatMessages[index].isStreaming = false
        streamingMessageId = nil
        saveChatState()
    }

    func abandonStreamingMessage() {
        guard let streamingId = streamingMessageId,
              let index = chatMessages.firstIndex(where: { $0.id == streamingId }) else {
            streamingMessageId = nil
            saveChatState()
            return
        }

        let message = chatMessages[index]
        if message.segments.isEmpty && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chatMessages.remove(at: index)
        } else {
            chatMessages[index].isStreaming = false
        }
        streamingMessageId = nil
        saveChatState()
    }

    // MARK: - Message Composition Helpers

    /// Adds a user message to the chat with optional images.
    func addUserMessage(content: String, images: [ChatImageData]) {
        let sanitizedContent = ChatMessage.sanitizedUserContent(content)
        let message = ChatMessage(role: .user, content: sanitizedContent, isStreaming: false, images: images)
        chatMessages.append(message)
        saveChatState()
    }

    /// Adds a completed assistant message to the chat.
    func addAssistantMessage(_ content: String) {
        let message = ChatMessage(role: .assistant, content: content, isStreaming: false)
        chatMessages.append(message)
        saveChatState()
    }

    /// Adds a system message (informational, not error) to the chat.
    func addSystemMessage(_ content: String) {
        let message = ChatMessage(role: .system, content: content, isStreaming: false, isError: false)
        chatMessages.append(message)
        saveChatState()
    }

    /// Starts a new streaming assistant response.
    func startNewStreamingResponse() {
        let streaming = ChatMessage(role: .assistant, content: "", isStreaming: true)
        chatMessages.append(streaming)
        streamingMessageId = streaming.id
        restoreStreamingState(from: chatMessages)
        saveChatState()
    }

    /// Adds a system error message to the chat.
    func addSystemErrorMessage(_ message: String) {
        chatMessages.append(ChatMessage(role: .system, content: message, isStreaming: false, isError: true))
        saveChatState()
    }

    // MARK: - Chat State Management

    /// Set the current session context for state management.
    func setSessionContext(serverId: UUID?, sessionId: String?) {
        currentServerId = serverId
        currentSessionId = sessionId
    }

    /// Save current chat messages and stop reason to cache.
    func saveChatState() {
        guard let serverId = currentServerId, let sessionId = currentSessionId, !sessionId.isEmpty else { return }

        // Save to cache via delegate
        cacheDelegate?.saveMessages(chatMessages, for: serverId, sessionId: sessionId)
        if !stopReason.isEmpty {
            cacheDelegate?.saveStopReason(stopReason, for: serverId, sessionId: sessionId)
        }

        // Persist to storage if needed (for agents without session/load support)
        cacheDelegate?.persistChatToStorage(serverId: serverId, sessionId: sessionId)
    }

    /// Load chat messages and stop reason from cache or storage.
    func loadChatState(serverId: UUID, sessionId: String, canLoadFromStorage: Bool) {
        currentServerId = serverId
        currentSessionId = sessionId

        // Check cache first via delegate
        if let cachedChat = cacheDelegate?.loadMessages(for: serverId, sessionId: sessionId) {
            chatMessages = cachedChat
        } else if canLoadFromStorage {
            let storedMessages = cacheDelegate?.loadChatFromStorage(sessionId: sessionId, serverId: serverId) ?? []
            if !storedMessages.isEmpty {
                chatMessages = storedMessages
                // Populate cache via delegate
                cacheDelegate?.saveMessages(storedMessages, for: serverId, sessionId: sessionId)
                dependencies.append("Restored \(storedMessages.count) message(s) from local storage")
            } else {
                chatMessages = []
            }
        } else {
            chatMessages = []
        }

        // Load stop reason from cache via delegate
        if let cachedStop = cacheDelegate?.loadStopReason(for: serverId, sessionId: sessionId) {
            stopReason = cachedStop
        } else {
            stopReason = ""
        }

        restoreStreamingState(from: chatMessages)
    }

    /// Reset chat state (clear messages and stop reason).
    func resetChatState() {
        chatMessages = []
        stopReason = ""
        streamingMessageId = nil
        currentServerId = nil
        currentSessionId = nil
    }

    /// Set stop reason and save to cache.
    func setStopReason(_ reason: String) {
        stopReason = reason
        saveChatState()
    }

    /// Handle stop reason received from server.
    func handleStopReason(_ reason: String, serverId: UUID, sessionId: String) {
        setStopReason(reason)
        finishStreamingMessage()
        // Notify delegate
        eventDelegate?.sessionDidReceiveStopReason(reason, serverId: serverId, sessionId: sessionId)
    }

    /// Handle session load completion.
    func handleSessionLoadCompleted(serverId: UUID, sessionId: String) {
        if !isReplayingRecovery(sessionId: sessionId) {
            finishStreamingMessage()
        }
        // Notify delegate
        eventDelegate?.sessionLoadDidComplete(serverId: serverId, sessionId: sessionId)
    }

    /// Set chat messages directly (for backward compatibility).
    func setChatMessages(_ messages: [ChatMessage]) {
        chatMessages = messages
        restoreStreamingState(from: messages)
    }
}
