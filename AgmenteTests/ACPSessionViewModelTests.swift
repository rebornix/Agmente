import XCTest
import ACP
@testable import Agmente
import ACPClient

@MainActor
final class ACPSessionViewModelTests: XCTestCase {

    // MARK: - Mock Delegates

    /// Mock implementation of ACPSessionCacheDelegate for testing.
    private final class MockCacheDelegate: ACPSessionCacheDelegate {
        var savedMessages: [UUID: [String: [ChatMessage]]] = [:]
        var savedStopReasons: [UUID: [String: String]] = [:]
        var saveCalls: [(serverId: UUID, sessionId: String)] = []
        var loadCalls: [(serverId: UUID, sessionId: String)] = []
        var clearCalls: [(serverId: UUID, sessionId: String?)] = []
        var migrateCalls: [(serverId: UUID, from: String, to: String)] = []
        var storedMessages: [String: [UUID: [ChatMessage]]] = [:] // sessionId -> serverId -> messages
        var persistCalls: [(serverId: UUID, sessionId: String)] = []

        func saveMessages(_ messages: [ChatMessage], for serverId: UUID, sessionId: String) {
            var serverCache = savedMessages[serverId] ?? [:]
            serverCache[sessionId] = messages
            savedMessages[serverId] = serverCache
            saveCalls.append((serverId, sessionId))
        }

        func loadMessages(for serverId: UUID, sessionId: String) -> [ChatMessage]? {
            loadCalls.append((serverId, sessionId))
            return savedMessages[serverId]?[sessionId]
        }

        func saveStopReason(_ reason: String, for serverId: UUID, sessionId: String) {
            var serverCache = savedStopReasons[serverId] ?? [:]
            serverCache[sessionId] = reason
            savedStopReasons[serverId] = serverCache
        }

        func loadStopReason(for serverId: UUID, sessionId: String) -> String? {
            return savedStopReasons[serverId]?[sessionId]
        }

        func clearCache(for serverId: UUID, sessionId: String) {
            savedMessages[serverId]?[sessionId] = nil
            savedStopReasons[serverId]?[sessionId] = nil
            clearCalls.append((serverId, sessionId))
        }

        func clearCache(for serverId: UUID) {
            savedMessages[serverId] = nil
            savedStopReasons[serverId] = nil
            clearCalls.append((serverId, nil))
        }

        func migrateCache(serverId: UUID, from placeholderId: String, to resolvedId: String) {
            migrateCalls.append((serverId, placeholderId, resolvedId))
            if let messages = savedMessages[serverId]?[placeholderId] {
                saveMessages(messages, for: serverId, sessionId: resolvedId)
            }
            if let stopReason = savedStopReasons[serverId]?[placeholderId] {
                saveStopReason(stopReason, for: serverId, sessionId: resolvedId)
            }
        }

        func hasCachedMessages(serverId: UUID, sessionId: String) -> Bool {
            return savedMessages[serverId]?[sessionId] != nil
        }

        func getLastMessagePreview(for serverId: UUID, sessionId: String) -> String? {
            return savedMessages[serverId]?[sessionId]?.last?.content
        }

        func loadChatFromStorage(sessionId: String, serverId: UUID) -> [ChatMessage] {
            return storedMessages[sessionId]?[serverId] ?? []
        }

        func persistChatToStorage(serverId: UUID, sessionId: String) {
            persistCalls.append((serverId, sessionId))
        }

        func reset() {
            savedMessages = [:]
            savedStopReasons = [:]
            saveCalls = []
            loadCalls = []
            clearCalls = []
            migrateCalls = []
            storedMessages = [:]
            persistCalls = []
        }
    }

    /// Mock implementation of ACPSessionEventDelegate for testing.
    private final class MockEventDelegate: ACPSessionEventDelegate {
        var modeChanges: [(modeId: String, serverId: UUID, sessionId: String)] = []
        var stopReasons: [(reason: String, serverId: UUID, sessionId: String)] = []
        var loadCompletions: [(serverId: UUID, sessionId: String)] = []

        func sessionModeDidChange(_ modeId: String, serverId: UUID, sessionId: String) {
            modeChanges.append((modeId, serverId, sessionId))
        }

        func sessionDidReceiveStopReason(_ reason: String, serverId: UUID, sessionId: String) {
            stopReasons.append((reason, serverId, sessionId))
        }

        func sessionLoadDidComplete(serverId: UUID, sessionId: String) {
            loadCompletions.append((serverId, sessionId))
        }

        func reset() {
            modeChanges = []
            stopReasons = []
            loadCompletions = []
        }
    }

    // MARK: - Test Helpers

    private var appendMessages: [String] = []
    private var wireMessages: [(direction: String, message: ACPWireMessage)] = []

    private func makeDependencies(service: ACPService? = nil) -> ACPSessionViewModel.Dependencies {
        return ACPSessionViewModel.Dependencies(
            getService: { service },
            append: { [weak self] message in
                self?.appendMessages.append(message)
            },
            logWire: { [weak self] direction, message in
                self?.wireMessages.append((direction, message))
            }
        )
    }

    private func makeViewModel(service: ACPService? = nil, cacheDelegate: ACPSessionCacheDelegate? = nil, eventDelegate: ACPSessionEventDelegate? = nil) -> ACPSessionViewModel {
        let viewModel = ACPSessionViewModel(dependencies: makeDependencies(service: service))
        viewModel.cacheDelegate = cacheDelegate
        viewModel.eventDelegate = eventDelegate
        return viewModel
    }

    private func resetTestState() {
        appendMessages = []
        wireMessages = []
    }

    override func setUp() {
        super.setUp()
        resetTestState()
    }

    // MARK: - Chat State Management Tests

    func testSaveChatState_DelegatesToCache() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        // Set session context
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        // Add some messages
        viewModel.addUserMessage(content: "Hello", images: [])

        // Verify cache delegate was called
        XCTAssertFalse(cacheDelegate.saveCalls.isEmpty, "saveChatState should call cacheDelegate.saveMessages")
        XCTAssertEqual(cacheDelegate.saveCalls.last?.serverId, serverId)
        XCTAssertEqual(cacheDelegate.saveCalls.last?.sessionId, sessionId)
        XCTAssertEqual(cacheDelegate.savedMessages[serverId]?[sessionId]?.count, 1)
        XCTAssertEqual(cacheDelegate.savedMessages[serverId]?[sessionId]?.first?.content, "Hello")
    }

    func testSaveChatState_WithStopReason_SavesBoth() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)
        viewModel.setStopReason("max_tokens")

        // Verify stop reason was saved
        XCTAssertEqual(cacheDelegate.savedStopReasons[serverId]?[sessionId], "max_tokens")
    }

    func testSaveChatState_WithoutSessionContext_DoesNotSave() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        // Don't set session context
        viewModel.addUserMessage(content: "Hello", images: [])

        // Verify no save occurred
        XCTAssertTrue(cacheDelegate.saveCalls.isEmpty, "Should not save without session context")
    }

    func testLoadChatState_FromCache_LoadsSuccessfully() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        // Pre-populate cache
        let cachedMessages = [
            ChatMessage(role: .user, content: "Cached message", isStreaming: false)
        ]
        cacheDelegate.saveMessages(cachedMessages, for: serverId, sessionId: sessionId)
        cacheDelegate.saveStopReason("end_turn", for: serverId, sessionId: sessionId)

        // Load state
        viewModel.loadChatState(serverId: serverId, sessionId: sessionId, canLoadFromStorage: false)

        // Verify loaded from cache
        XCTAssertEqual(viewModel.chatMessages.count, 1)
        XCTAssertEqual(viewModel.chatMessages.first?.content, "Cached message")
        XCTAssertEqual(viewModel.stopReason, "end_turn")
        XCTAssertFalse(cacheDelegate.loadCalls.isEmpty, "Should have called loadMessages")
    }

    func testLoadChatState_FromStorage_WhenCacheEmpty() {
        let cacheDelegate = MockCacheDelegate()
        let viewModel = makeViewModel(cacheDelegate: cacheDelegate)

        let serverId = UUID()
        let sessionId = "test-session"

        // Pre-populate storage
        let messages = [
            ChatMessage(role: .user, content: "Stored message", isStreaming: false)
        ]
        cacheDelegate.storedMessages[sessionId] = [serverId: messages]

        // Load state (cache is empty, should fallback to storage)
        viewModel.loadChatState(serverId: serverId, sessionId: sessionId, canLoadFromStorage: true)

        // Verify loaded from storage
        XCTAssertEqual(viewModel.chatMessages.count, 1)
        XCTAssertEqual(viewModel.chatMessages.first?.content, "Stored message")

        // Verify storage messages were cached
        XCTAssertEqual(cacheDelegate.savedMessages[serverId]?[sessionId]?.count, 1)

        // Verify append message was called
        XCTAssertTrue(appendMessages.contains { $0.contains("Restored 1 message") })
    }

    func testLoadChatState_EmptyCacheAndNoStorage_LoadsEmpty() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        // Load state (nothing in cache or storage)
        viewModel.loadChatState(serverId: serverId, sessionId: sessionId, canLoadFromStorage: true)

        // Verify empty state
        XCTAssertTrue(viewModel.chatMessages.isEmpty)
        XCTAssertEqual(viewModel.stopReason, "")
    }

    func testResetChatState_ClearsAllState() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        // Set up some state
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)
        viewModel.addUserMessage(content: "Test", images: [])
        viewModel.setStopReason("max_tokens")

        // Reset
        viewModel.resetChatState()

        // Verify all state cleared
        XCTAssertTrue(viewModel.chatMessages.isEmpty)
        XCTAssertEqual(viewModel.stopReason, "")
    }

    func testSetChatMessages_SetsDirectly() {
        let viewModel = makeViewModel()

        let messages = [
            ChatMessage(role: .user, content: "Message 1", isStreaming: false),
            ChatMessage(role: .assistant, content: "Message 2", isStreaming: false)
        ]

        viewModel.setChatMessages(messages)

        XCTAssertEqual(viewModel.chatMessages.count, 2)
        XCTAssertEqual(viewModel.chatMessages[0].content, "Message 1")
        XCTAssertEqual(viewModel.chatMessages[1].content, "Message 2")
    }

    // MARK: - Event Delegate Tests

    func testHandleStopReason_CallsDelegate() {
        let viewModel = makeViewModel()
        let eventDelegate = MockEventDelegate()
        viewModel.eventDelegate = eventDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)
        viewModel.handleStopReason("max_tokens", serverId: serverId, sessionId: sessionId)

        // Verify delegate was called
        XCTAssertEqual(eventDelegate.stopReasons.count, 1)
        XCTAssertEqual(eventDelegate.stopReasons.first?.reason, "max_tokens")
        XCTAssertEqual(eventDelegate.stopReasons.first?.serverId, serverId)
        XCTAssertEqual(eventDelegate.stopReasons.first?.sessionId, sessionId)

        // Verify stop reason was set
        XCTAssertEqual(viewModel.stopReason, "max_tokens")
    }

    func testHandleSessionLoadCompleted_CallsDelegate() {
        let viewModel = makeViewModel()
        let eventDelegate = MockEventDelegate()
        viewModel.eventDelegate = eventDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        viewModel.handleSessionLoadCompleted(serverId: serverId, sessionId: sessionId)

        // Verify delegate was called
        XCTAssertEqual(eventDelegate.loadCompletions.count, 1)
        XCTAssertEqual(eventDelegate.loadCompletions.first?.serverId, serverId)
        XCTAssertEqual(eventDelegate.loadCompletions.first?.sessionId, sessionId)
    }

    func testModeChange_CallsEventDelegate() {
        let viewModel = makeViewModel()
        let eventDelegate = MockEventDelegate()
        viewModel.eventDelegate = eventDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        // Simulate mode change event
        let params: ACP.Value = .object([
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("current_mode_update"),
                "modeId": .string("code")
            ])
        ])

        viewModel.handleChatUpdate(params, activeSessionId: sessionId, serverId: serverId)

        // Verify mode was updated
        XCTAssertEqual(viewModel.currentModeId, "code")

        // Verify delegate was called
        XCTAssertEqual(eventDelegate.modeChanges.count, 1)
        XCTAssertEqual(eventDelegate.modeChanges.first?.modeId, "code")
        XCTAssertEqual(eventDelegate.modeChanges.first?.serverId, serverId)
        XCTAssertEqual(eventDelegate.modeChanges.first?.sessionId, sessionId)
    }

    // MARK: - Message Composition Tests

    func testAddUserMessage_AddsToChat() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        viewModel.addUserMessage(content: "Hello world", images: [])

        XCTAssertEqual(viewModel.chatMessages.count, 1)
        XCTAssertEqual(viewModel.chatMessages.first?.role, .user)
        XCTAssertEqual(viewModel.chatMessages.first?.content, "Hello world")
        XCTAssertFalse(viewModel.chatMessages.first?.isStreaming ?? true)
    }

    func testStartNewStreamingResponse_AddsStreamingMessage() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        viewModel.startNewStreamingResponse()

        XCTAssertEqual(viewModel.chatMessages.count, 1)
        XCTAssertEqual(viewModel.chatMessages.first?.role, .assistant)
        XCTAssertEqual(viewModel.chatMessages.first?.content, "")
        XCTAssertTrue(viewModel.chatMessages.first?.isStreaming ?? false)
    }

    func testAddSystemErrorMessage_AddsErrorMessage() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        viewModel.addSystemErrorMessage("Connection failed")

        XCTAssertEqual(viewModel.chatMessages.count, 1)
        XCTAssertEqual(viewModel.chatMessages.first?.role, .system)
        XCTAssertEqual(viewModel.chatMessages.first?.content, "Connection failed")
        XCTAssertTrue(viewModel.chatMessages.first?.isError ?? false)
    }

    // MARK: - Mode State Management Tests

    func testSetCurrentModeId_UpdatesMode() {
        let viewModel = makeViewModel()

        viewModel.setCurrentModeId("test-mode")

        XCTAssertEqual(viewModel.currentModeId, "test-mode")
    }

    func testCacheCurrentMode_StoresMode() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let sessionId = "test-session"

        viewModel.setCurrentModeId("code")
        viewModel.cacheCurrentMode(serverId: serverId, sessionId: sessionId)

        let cached = viewModel.cachedMode(for: serverId, sessionId: sessionId)
        XCTAssertEqual(cached, "code")
    }

    func testMigrateSessionModeCache_MigratesSuccessfully() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let placeholderId = "placeholder-123"
        let resolvedId = "resolved-456"

        // Set mode for placeholder
        viewModel.setCurrentModeId("test-mode")
        viewModel.cacheCurrentMode(serverId: serverId, sessionId: placeholderId)

        // Migrate
        viewModel.migrateSessionModeCache(for: serverId, from: placeholderId, to: resolvedId)

        // Verify migrated
        XCTAssertEqual(viewModel.cachedMode(for: serverId, sessionId: resolvedId), "test-mode")
    }

    func testMigrateSessionModeCache_DoesNotOverwriteExisting() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let placeholderId = "placeholder-123"
        let resolvedId = "resolved-456"

        // Set mode for both
        viewModel.setCurrentModeId("mode-1")
        viewModel.cacheCurrentMode(serverId: serverId, sessionId: placeholderId)

        viewModel.setCurrentModeId("mode-2")
        viewModel.cacheCurrentMode(serverId: serverId, sessionId: resolvedId)

        // Migrate (should not overwrite)
        viewModel.migrateSessionModeCache(for: serverId, from: placeholderId, to: resolvedId)

        // Verify not overwritten
        XCTAssertEqual(viewModel.cachedMode(for: serverId, sessionId: resolvedId), "mode-2")
    }

    // MARK: - State Transition Tests

    func testStateTransition_LoadActiveReset() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        // 1. Load state (empty)
        viewModel.loadChatState(serverId: serverId, sessionId: sessionId, canLoadFromStorage: false)
        XCTAssertTrue(viewModel.chatMessages.isEmpty)

        // 2. Active - add messages
        viewModel.addUserMessage(content: "Message 1", images: [])
        viewModel.addUserMessage(content: "Message 2", images: [])
        XCTAssertEqual(viewModel.chatMessages.count, 2)

        // 3. Reset
        viewModel.resetChatState()
        XCTAssertTrue(viewModel.chatMessages.isEmpty)
    }

    func testStateTransition_SaveAndReload() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        // Set context and add messages
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)
        viewModel.addUserMessage(content: "Saved message", images: [])
        viewModel.setStopReason("end_turn")

        // Verify saved to cache
        XCTAssertFalse(cacheDelegate.savedMessages.isEmpty)

        // Reset and reload
        viewModel.resetChatState()
        XCTAssertTrue(viewModel.chatMessages.isEmpty)

        viewModel.loadChatState(serverId: serverId, sessionId: sessionId, canLoadFromStorage: false)

        // Verify reloaded
        XCTAssertEqual(viewModel.chatMessages.count, 1)
        XCTAssertEqual(viewModel.chatMessages.first?.content, "Saved message")
        XCTAssertEqual(viewModel.stopReason, "end_turn")
    }

    func testMultipleSessionsCache_IsolatedProperly() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId1 = UUID()
        let serverId2 = UUID()
        let sessionId1 = "session-1"
        let sessionId2 = "session-2"

        // Session 1
        viewModel.loadChatState(serverId: serverId1, sessionId: sessionId1, canLoadFromStorage: false)
        viewModel.addUserMessage(content: "Session 1 message", images: [])

        // Switch to Session 2
        viewModel.loadChatState(serverId: serverId2, sessionId: sessionId2, canLoadFromStorage: false)
        viewModel.addUserMessage(content: "Session 2 message", images: [])

        // Verify both cached independently
        XCTAssertEqual(cacheDelegate.savedMessages[serverId1]?[sessionId1]?.first?.content, "Session 1 message")
        XCTAssertEqual(cacheDelegate.savedMessages[serverId2]?[sessionId2]?.first?.content, "Session 2 message")

        // Load session 1 back
        viewModel.loadChatState(serverId: serverId1, sessionId: sessionId1, canLoadFromStorage: false)
        XCTAssertEqual(viewModel.chatMessages.first?.content, "Session 1 message")
    }

    func testStreamingStateRestore_AfterLoad() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        // Create messages with streaming state
        let messages = [
            ChatMessage(role: .user, content: "Question", isStreaming: false),
            ChatMessage(role: .assistant, content: "Partial answer...", isStreaming: true)
        ]
        cacheDelegate.saveMessages(messages, for: serverId, sessionId: sessionId)

        // Load and verify streaming state restored
        viewModel.loadChatState(serverId: serverId, sessionId: sessionId, canLoadFromStorage: false)

        XCTAssertEqual(viewModel.chatMessages.count, 2)
        XCTAssertTrue(viewModel.chatMessages.last?.isStreaming ?? false)
    }

    // MARK: - Commands Tests

    func testHandleAvailableCommandsUpdate_UpdatesCommands() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let sessionId = "test-session"

        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        let commands = [
            SessionCommand(id: "cmd1", name: "test-command", description: "Test", inputHint: nil)
        ]

        viewModel.handleAvailableCommandsUpdate(commands, serverId: serverId, sessionId: sessionId)

        XCTAssertEqual(viewModel.availableCommands.count, 1)
        XCTAssertEqual(viewModel.availableCommands.first?.name, "test-command")
    }

    func testRestoreAvailableCommands_FromCache() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let sessionId = "test-session"

        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        // Set and cache commands
        let commands = [
            SessionCommand(id: "cmd1", name: "cached-command", description: "Test", inputHint: nil)
        ]
        viewModel.handleAvailableCommandsUpdate(commands, serverId: serverId, sessionId: sessionId)

        // Reset
        viewModel.resetCommands()
        XCTAssertTrue(viewModel.availableCommands.isEmpty)

        // Restore
        viewModel.restoreAvailableCommands(for: serverId, sessionId: sessionId, isNew: false)
        XCTAssertEqual(viewModel.availableCommands.count, 1)
        XCTAssertEqual(viewModel.availableCommands.first?.name, "cached-command")
    }

    func testMigrateSessionCommandsCache_MigratesSuccessfully() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let placeholderId = "placeholder-123"
        let resolvedId = "resolved-456"

        viewModel.setSessionContext(serverId: serverId, sessionId: placeholderId)

        // Set commands for placeholder
        let commands = [
            SessionCommand(id: "cmd1", name: "test-command", description: "Test", inputHint: nil)
        ]
        viewModel.handleAvailableCommandsUpdate(commands, serverId: serverId, sessionId: placeholderId)

        // Migrate
        viewModel.migrateSessionCommandsCache(for: serverId, from: placeholderId, to: resolvedId)

        // Verify migrated
        viewModel.restoreAvailableCommands(for: serverId, sessionId: resolvedId, isNew: false)
        XCTAssertEqual(viewModel.availableCommands.count, 1)
        XCTAssertEqual(viewModel.availableCommands.first?.name, "test-command")
    }
}