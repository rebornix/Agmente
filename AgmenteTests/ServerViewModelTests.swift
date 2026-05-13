import XCTest
import ACP
import ACPClient
@testable import Agmente

@MainActor
final class ServerViewModelTests: XCTestCase {
    private final class TestCacheDelegate: ACPSessionCacheDelegate {
        var messages: [UUID: [String: [ChatMessage]]] = [:]
        var stopReasons: [UUID: [String: String]] = [:]

        func saveMessages(_ messages: [ChatMessage], for serverId: UUID, sessionId: String) {
            var serverMessages = self.messages[serverId] ?? [:]
            serverMessages[sessionId] = messages
            self.messages[serverId] = serverMessages
        }

        func loadMessages(for serverId: UUID, sessionId: String) -> [ChatMessage]? {
            messages[serverId]?[sessionId]
        }

        func saveStopReason(_ reason: String, for serverId: UUID, sessionId: String) {
            var serverReasons = stopReasons[serverId] ?? [:]
            serverReasons[sessionId] = reason
            stopReasons[serverId] = serverReasons
        }

        func loadStopReason(for serverId: UUID, sessionId: String) -> String? {
            stopReasons[serverId]?[sessionId]
        }

        func clearCache(for serverId: UUID, sessionId: String) {
            messages[serverId]?[sessionId] = nil
            stopReasons[serverId]?[sessionId] = nil
        }

        func clearCache(for serverId: UUID) {
            messages[serverId] = nil
            stopReasons[serverId] = nil
        }

        func migrateCache(serverId: UUID, from placeholderId: String, to resolvedId: String) {
            if let chat = messages[serverId]?[placeholderId], messages[serverId]?[resolvedId] == nil {
                messages[serverId, default: [:]][resolvedId] = chat
            }
            if let reason = stopReasons[serverId]?[placeholderId], stopReasons[serverId]?[resolvedId] == nil {
                stopReasons[serverId, default: [:]][resolvedId] = reason
            }
        }

        func hasCachedMessages(serverId: UUID, sessionId: String) -> Bool {
            messages[serverId]?[sessionId]?.isEmpty == false
        }

        func getLastMessagePreview(for serverId: UUID, sessionId: String) -> String? {
            messages[serverId]?[sessionId]?.last?.content
        }

        func loadChatFromStorage(sessionId: String, serverId: UUID) -> [ChatMessage] {
            []
        }

        func persistChatToStorage(serverId: UUID, sessionId: String) {}
    }

    private final class StorageBackedCacheDelegate: ACPSessionCacheDelegate {
        private let storage: SessionStorage
        var messages: [UUID: [String: [ChatMessage]]] = [:]
        var stopReasons: [UUID: [String: String]] = [:]

        init(storage: SessionStorage) {
            self.storage = storage
        }

        func saveMessages(_ messages: [ChatMessage], for serverId: UUID, sessionId: String) {
            var serverMessages = self.messages[serverId] ?? [:]
            serverMessages[sessionId] = messages
            self.messages[serverId] = serverMessages
        }

        func loadMessages(for serverId: UUID, sessionId: String) -> [ChatMessage]? {
            messages[serverId]?[sessionId]
        }

        func saveStopReason(_ reason: String, for serverId: UUID, sessionId: String) {
            var serverReasons = stopReasons[serverId] ?? [:]
            serverReasons[sessionId] = reason
            stopReasons[serverId] = serverReasons
        }

        func loadStopReason(for serverId: UUID, sessionId: String) -> String? {
            stopReasons[serverId]?[sessionId]
        }

        func clearCache(for serverId: UUID, sessionId: String) {
            messages[serverId]?[sessionId] = nil
            stopReasons[serverId]?[sessionId] = nil
        }

        func clearCache(for serverId: UUID) {
            messages[serverId] = nil
            stopReasons[serverId] = nil
        }

        func migrateCache(serverId: UUID, from placeholderId: String, to resolvedId: String) {
            if let chat = messages[serverId]?[placeholderId], messages[serverId]?[resolvedId] == nil {
                messages[serverId, default: [:]][resolvedId] = chat
            }
            if let reason = stopReasons[serverId]?[placeholderId], stopReasons[serverId]?[resolvedId] == nil {
                stopReasons[serverId, default: [:]][resolvedId] = reason
            }
        }

        func hasCachedMessages(serverId: UUID, sessionId: String) -> Bool {
            messages[serverId]?[sessionId]?.isEmpty == false
        }

        func getLastMessagePreview(for serverId: UUID, sessionId: String) -> String? {
            messages[serverId]?[sessionId]?.last?.content
        }

        func loadChatFromStorage(sessionId: String, serverId: UUID) -> [ChatMessage] {
            storage.fetchMessages(forSessionId: sessionId, serverId: serverId).map(ChatMessage.init(from:))
        }

        func persistChatToStorage(serverId: UUID, sessionId: String) {
            let storedMessages = (messages[serverId]?[sessionId] ?? []).filter { !$0.isStreaming }.map { $0.toStoredInfo() }
            guard !storedMessages.isEmpty else { return }
            storage.saveMessages(storedMessages, forSessionId: sessionId, serverId: serverId)
        }
    }

    private final class RecordingWebSocketConnection: WebSocketConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var events: [WebSocketEvent] = []
        private(set) var sentTexts: [String] = []

        func connect(headers: [String : String]) async throws {}

        func send(text: String) async throws {
            lock.lock()
            sentTexts.append(text)
            lock.unlock()
        }

        func receive() async throws -> WebSocketEvent {
            while true {
                lock.lock()
                if !events.isEmpty {
                    let event = events.removeFirst()
                    lock.unlock()
                    return event
                }
                lock.unlock()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        func close() async {}
        func ping() async throws {}

        func enqueue(_ event: WebSocketEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func sentTextsSnapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return sentTexts
        }
    }

    private struct RecordingWebSocketProvider: WebSocketProviding, @unchecked Sendable {
        let connection: RecordingWebSocketConnection

        func makeConnection(url: URL) -> WebSocketConnection {
            connection
        }
    }

    private func extractRequest(from text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sentRequests(connection: RecordingWebSocketConnection) -> [[String: Any]] {
        connection.sentTextsSnapshot().compactMap { text in
            try? extractRequest(from: text)
        }
    }

    private func hasSentRequest(connection: RecordingWebSocketConnection, method: String) -> Bool {
        sentRequests(connection: connection).contains { request in
            request["method"] as? String == method
        }
    }

    private func waitForSentRequest(
        connection: RecordingWebSocketConnection,
        method: String,
        attempts: Int = 200
    ) async -> [String: Any]? {
        for _ in 0..<attempts {
            if let request = sentRequests(connection: connection).first(where: { $0["method"] as? String == method }) {
                return request
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func enqueueResponse(id: Int, result: ACP.Value, on connection: RecordingWebSocketConnection) throws {
        let response = ACPWireMessage.response(.init(id: .int(id), result: result))
        let data = try JSONEncoder().encode(response)
        let text = String(decoding: data, as: UTF8.self)
        connection.enqueue(.text(text))
    }

    private func enqueueError(id: Int, error: ACPError, on connection: RecordingWebSocketConnection) throws {
        let response = ACPWireMessage.response(.init(id: .int(id), error: error))
        let data = try JSONEncoder().encode(response)
        let text = String(decoding: data, as: UTF8.self)
        connection.enqueue(.text(text))
    }

    private func makeStoredServer(id: UUID, workingDirectory: String = "/tmp") -> ACPServerConfiguration {
        ACPServerConfiguration(
            id: id,
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            cfAccessClientId: "",
            cfAccessClientSecret: "",
            workingDirectory: workingDirectory,
            serverType: .acp
        )
    }

    func testPendingWorkingDirectoryUpdateFlowsIntoSessionCreationAndPrompt() async throws {
        let connection = RecordingWebSocketConnection()
        let provider = RecordingWebSocketProvider(connection: connection)
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://localhost:1234")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let suiteName = "ServerViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.setServiceForTesting(service)

        Task {
            guard let initRequest = await self.waitForSentRequest(connection: connection, method: "initialize"),
                  let initId = initRequest["id"] as? Int else {
                return
            }
            try? self.enqueueResponse(id: initId, result: .object(["status": .string("ok")]), on: connection)
        }

        let initialized = await manager.initializeAndWait(
            payload: ACPInitializationPayload(clientName: "Agmente iOS", clientVersion: "0.1.0")
        )
        XCTAssertTrue(initialized)

        let storage = SessionStorage.inMemory()
        let cacheDelegate = TestCacheDelegate()
        let serverId = UUID()
        let serverViewModel = ServerViewModel(
            id: serverId,
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            workingDirectory: "/default",
            connectionManager: manager,
            getService: { manager.service },
            append: { _ in },
            logWire: { _, _ in },
            cacheDelegate: cacheDelegate,
            storage: storage
        )

        serverViewModel.sendNewSession()
        let placeholderId = try XCTUnwrap(serverViewModel.selectedSessionId)
        XCTAssertTrue(serverViewModel.isPendingSession)

        serverViewModel.updatePendingSessionWorkingDirectory("/tmp/custom-project")

        Task {
            guard let newSessionRequest = await self.waitForSentRequest(connection: connection, method: "session/new"),
                  let newSessionId = newSessionRequest["id"] as? Int else {
                return
            }
            try? self.enqueueResponse(
                id: newSessionId,
                result: .object([
                    "sessionId": .string("server-session-123"),
                    "cwd": .string("/tmp/custom-project")
                ]),
                on: connection
            )

            guard let promptRequest = await self.waitForSentRequest(connection: connection, method: "session/prompt"),
                  let promptId = promptRequest["id"] as? Int else {
                return
            }
            try? self.enqueueResponse(
                id: promptId,
                result: .object(["stopReason": .string("end_turn")]),
                on: connection
            )
        }

        serverViewModel.sendPrompt(promptText: "hello", images: [])

        let newSessionRequestMaybe = await waitForSentRequest(connection: connection, method: "session/new")
        let newSessionRequest = try XCTUnwrap(newSessionRequestMaybe)
        let newSessionParams = try XCTUnwrap(newSessionRequest["params"] as? [String: Any])
        XCTAssertEqual(newSessionParams["cwd"] as? String, "/tmp/custom-project")

        let promptRequestMaybe = await waitForSentRequest(connection: connection, method: "session/prompt")
        let promptRequest = try XCTUnwrap(promptRequestMaybe)
        let promptParams = try XCTUnwrap(promptRequest["params"] as? [String: Any])
        XCTAssertEqual(promptParams["sessionId"] as? String, "server-session-123")
        XCTAssertNotEqual(promptParams["sessionId"] as? String, placeholderId)
        XCTAssertFalse(hasSentRequest(connection: connection, method: "session/load"))

        let currentMessages = try XCTUnwrap(serverViewModel.currentSessionViewModel?.chatMessages)
        XCTAssertEqual(currentMessages.first?.content, "hello")
        XCTAssertEqual(cacheDelegate.messages[serverId]?["server-session-123"]?.first?.content, "hello")
        XCTAssertNil(cacheDelegate.messages[serverId]?[placeholderId])
    }

    func testFreshlyCreatedEmptySessionDoesNotTriggerSessionLoad() async throws {
        let connection = RecordingWebSocketConnection()
        let provider = RecordingWebSocketProvider(connection: connection)
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://localhost:1234")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let suiteName = "ServerViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.setServiceForTesting(service)

        Task {
            guard let initRequest = await self.waitForSentRequest(connection: connection, method: "initialize"),
                  let initId = initRequest["id"] as? Int else {
                return
            }
            try? self.enqueueResponse(id: initId, result: .object(["status": .string("ok")]), on: connection)
        }

        let initialized = await manager.initializeAndWait(
            payload: ACPInitializationPayload(clientName: "Agmente iOS", clientVersion: "0.1.0")
        )
        XCTAssertTrue(initialized)

        let serverViewModel = ServerViewModel(
            id: UUID(),
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            workingDirectory: "/tmp",
            connectionManager: manager,
            getService: { manager.service },
            append: { _ in },
            logWire: { _, _ in },
            cacheDelegate: TestCacheDelegate(),
            storage: SessionStorage.inMemory()
        )

        Task {
            guard let newSessionRequest = await self.waitForSentRequest(connection: connection, method: "session/new"),
                  let newSessionId = newSessionRequest["id"] as? Int else {
                return
            }
            try? self.enqueueResponse(
                id: newSessionId,
                result: .object([
                    "sessionId": .string("server-session-empty"),
                    "cwd": .string("/tmp")
                ]),
                on: connection
            )
        }

        serverViewModel.sendNewSession()

        let newSessionRequestMaybe = await waitForSentRequest(connection: connection, method: "session/new")
        _ = try XCTUnwrap(newSessionRequestMaybe)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(serverViewModel.sessionId, "server-session-empty")
        XCTAssertEqual(serverViewModel.lastLoadedSession, "server-session-empty")
        XCTAssertTrue(manager.isSessionMaterialized("server-session-empty"))
        XCTAssertFalse(hasSentRequest(connection: connection, method: "session/load"))

        serverViewModel.openSession("server-session-empty")

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(hasSentRequest(connection: connection, method: "session/load"))
    }

    func testFailedSessionCreationDoesNotSendPromptForPlaceholderSession() async throws {
        let connection = RecordingWebSocketConnection()
        let provider = RecordingWebSocketProvider(connection: connection)
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://localhost:1234")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let suiteName = "ServerViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.setServiceForTesting(service)

        Task {
            guard let initRequest = await self.waitForSentRequest(connection: connection, method: "initialize"),
                  let initId = initRequest["id"] as? Int else {
                return
            }
            try? self.enqueueResponse(id: initId, result: .object(["status": .string("ok")]), on: connection)
        }

        let initialized = await manager.initializeAndWait(
            payload: ACPInitializationPayload(clientName: "Agmente iOS", clientVersion: "0.1.0")
        )
        XCTAssertTrue(initialized)

        let serverViewModel = ServerViewModel(
            id: UUID(),
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            workingDirectory: "/Users/penlv/Code/Agmente-oss",
            connectionManager: manager,
            getService: { manager.service },
            append: { _ in },
            logWire: { _, _ in },
            cacheDelegate: TestCacheDelegate(),
            storage: SessionStorage.inMemory()
        )

        serverViewModel.sendNewSession()

        Task {
            guard let newSessionRequest = await self.waitForSentRequest(connection: connection, method: "session/new"),
                  let newSessionId = newSessionRequest["id"] as? Int else {
                return
            }
            try? self.enqueueError(
                id: newSessionId,
                error: .serverError(code: -32603, message: "Directory does not exist or cannot be accessed"),
                on: connection
            )
        }

        serverViewModel.sendPrompt(promptText: "hello", images: [])

        let newSessionRequestMaybe = await waitForSentRequest(connection: connection, method: "session/new")
        _ = try XCTUnwrap(newSessionRequestMaybe)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(serverViewModel.sessionId, "")
        XCTAssertNil(serverViewModel.selectedSessionId)
        XCTAssertFalse(hasSentRequest(connection: connection, method: "session/prompt"))
    }

    func testResolvedSessionReplacesPlaceholderInStorageAndPersistsTranscript() async throws {
        let connection = RecordingWebSocketConnection()
        let provider = RecordingWebSocketProvider(connection: connection)
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://localhost:1234")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let suiteName = "ServerViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.setServiceForTesting(service)

        Task {
            guard let initRequest = await self.waitForSentRequest(connection: connection, method: "initialize"),
                  let initId = initRequest["id"] as? Int else {
                return
            }
            try? self.enqueueResponse(id: initId, result: .object(["status": .string("ok")]), on: connection)
        }

        let didInitialize = await manager.initializeAndWait(
            payload: ACPInitializationPayload(clientName: "Agmente iOS", clientVersion: "0.1.0")
        )
        XCTAssertTrue(didInitialize)

        let serverId = UUID()
        let storage = SessionStorage.inMemory()
        storage.saveServer(makeStoredServer(id: serverId))
        let cacheDelegate = StorageBackedCacheDelegate(storage: storage)
        let serverViewModel = ServerViewModel(
            id: serverId,
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            workingDirectory: "/tmp",
            connectionManager: manager,
            getService: { manager.service },
            append: { _ in },
            logWire: { _, _ in },
            cacheDelegate: cacheDelegate,
            storage: storage
        )

        Task {
            guard let newSessionRequest = await self.waitForSentRequest(connection: connection, method: "session/new"),
                  let newSessionId = newSessionRequest["id"] as? Int else {
                return
            }
            try? self.enqueueResponse(
                id: newSessionId,
                result: .object([
                    "sessionId": .string("copilot-session-1"),
                    "cwd": .string("/tmp")
                ]),
                on: connection
            )

            guard let promptRequest = await self.waitForSentRequest(connection: connection, method: "session/prompt"),
                  let promptId = promptRequest["id"] as? Int else {
                return
            }
            try? self.enqueueResponse(
                id: promptId,
                result: .object(["stopReason": .string("end_turn")]),
                on: connection
            )
        }

        serverViewModel.sendNewSession()
        let placeholderId = try XCTUnwrap(serverViewModel.selectedSessionId)

        serverViewModel.sendPrompt(promptText: "hello from copilot", images: [])
        try await Task.sleep(nanoseconds: 200_000_000)

        let storedSessions = storage.fetchSessions(forServerId: serverId)
        XCTAssertEqual(storedSessions.map(\.sessionId), ["copilot-session-1"])
        XCTAssertFalse(storedSessions.contains(where: { $0.sessionId == placeholderId }))

        let storedMessages = storage.fetchMessages(forSessionId: "copilot-session-1", serverId: serverId)
        XCTAssertEqual(storedMessages.first?.content, "hello from copilot")
        XCTAssertTrue(storage.fetchMessages(forSessionId: placeholderId, serverId: serverId).isEmpty)
    }

    func testCachedSessionsReopenFromStorageForLoadCapableAgents() async throws {
        let serverId = UUID()
        let storage = SessionStorage.inMemory()
        storage.saveServer(makeStoredServer(id: serverId))
        storage.saveSession(
            StoredSessionInfo(
                sessionId: "copilot-session-1",
                title: "hello from copilot",
                cwd: "/tmp",
                updatedAt: Date()
            ),
            forServerId: serverId
        )
        let restoredSnapshot = [ChatMessage(role: .user, content: "hello from copilot", isStreaming: false)]
        storage.saveMessages(
            restoredSnapshot.map { $0.toStoredInfo() },
            forSessionId: "copilot-session-1",
            serverId: serverId
        )

        let suiteName = "ServerViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        let cacheDelegate = StorageBackedCacheDelegate(storage: storage)

        let serverViewModel = ServerViewModel(
            id: serverId,
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            workingDirectory: "/tmp",
            connectionManager: manager,
            getService: { nil },
            append: { _ in },
            logWire: { _, _ in },
            cacheDelegate: cacheDelegate,
            storage: storage
        )

        serverViewModel.fetchSessionList()

        XCTAssertEqual(serverViewModel.sessionSummaries.map(\.id), ["copilot-session-1"])

        serverViewModel.openSession("copilot-session-1")

        let restoredMessages = try XCTUnwrap(serverViewModel.currentSessionViewModel?.chatMessages)
        XCTAssertEqual(restoredMessages.first?.content, "hello from copilot")
    }

    // MARK: - Session Re-materialization Tests

    func testOpenStoredSessionSendsSessionLoadWhenAgentSupportsIt() async throws {
        // Simulates: app restart with a persisted session, agent supports session/load.
        // The session is in Core Data but NOT materialized on the server.
        // openSession should call session/load to re-materialize.
        let connection = RecordingWebSocketConnection()
        let provider = RecordingWebSocketProvider(connection: connection)
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://localhost:1234")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let suiteName = "ServerViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.setServiceForTesting(service)

        // Initialize with loadSession: true
        Task {
            guard let initRequest = await self.waitForSentRequest(connection: connection, method: "initialize"),
                  let initId = initRequest["id"] as? Int else { return }
            try? self.enqueueResponse(id: initId, result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(true)
                ])
            ]), on: connection)
        }

        let initialized = await manager.initializeAndWait(
            payload: ACPInitializationPayload(clientName: "Agmente iOS", clientVersion: "0.1.0")
        )
        XCTAssertTrue(initialized)

        let serverId = UUID()
        let storage = SessionStorage.inMemory()
        storage.saveServer(makeStoredServer(id: serverId))
        storage.saveSession(
            StoredSessionInfo(sessionId: "stale-session-1", title: "old chat", cwd: "/tmp", updatedAt: Date()),
            forServerId: serverId
        )
        storage.saveMessages(
            [ChatMessage(role: .user, content: "old message", isStreaming: false).toStoredInfo()],
            forSessionId: "stale-session-1",
            serverId: serverId
        )

        let cacheDelegate = StorageBackedCacheDelegate(storage: storage)
        let serverViewModel = ServerViewModel(
            id: serverId,
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            workingDirectory: "/tmp",
            connectionManager: manager,
            getService: { manager.service },
            append: { _ in },
            logWire: { _, _ in },
            cacheDelegate: cacheDelegate,
            storage: storage
        )

        // Set agentInfo so canLoadSession() reads the real capability
        serverViewModel.updateAgentInfo(AgentProfile(
            id: nil, name: "test-agent", title: "Test", version: "1.0",
            description: nil, modes: [],
            capabilities: AgentCapabilityState(loadSession: true),
            verifications: []
        ))

        serverViewModel.fetchSessionList()
        XCTAssertFalse(manager.isSessionMaterialized("stale-session-1"))

        // Enqueue response for session/load
        Task {
            guard let loadRequest = await self.waitForSentRequest(connection: connection, method: "session/load"),
                  let loadId = loadRequest["id"] as? Int else { return }
            try? self.enqueueResponse(id: loadId, result: .object([:]), on: connection)
        }

        serverViewModel.openSession("stale-session-1")

        // Verify session/load was sent with the correct session ID
        let loadRequest = await waitForSentRequest(connection: connection, method: "session/load")
        XCTAssertNotNil(loadRequest, "session/load should be sent for a stored but non-materialized session")
        if let params = loadRequest?["params"] as? [String: Any] {
            XCTAssertEqual(params["sessionId"] as? String, "stale-session-1")
        }
    }

    func testOpenStoredSessionSkipsLoadWhenAgentDoesNotSupportIt() async throws {
        // Agent without session/load capability — should NOT call session/load,
        // just show cached messages.
        let connection = RecordingWebSocketConnection()
        let provider = RecordingWebSocketProvider(connection: connection)
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://localhost:1234")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let suiteName = "ServerViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.setServiceForTesting(service)

        Task {
            guard let initRequest = await self.waitForSentRequest(connection: connection, method: "initialize"),
                  let initId = initRequest["id"] as? Int else { return }
            try? self.enqueueResponse(id: initId, result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(false)
                ])
            ]), on: connection)
        }

        let initialized = await manager.initializeAndWait(
            payload: ACPInitializationPayload(clientName: "Agmente iOS", clientVersion: "0.1.0")
        )
        XCTAssertTrue(initialized)

        let serverId = UUID()
        let storage = SessionStorage.inMemory()
        storage.saveServer(makeStoredServer(id: serverId))
        storage.saveSession(
            StoredSessionInfo(sessionId: "stale-session-2", title: "old chat", cwd: "/tmp", updatedAt: Date()),
            forServerId: serverId
        )
        storage.saveMessages(
            [ChatMessage(role: .user, content: "cached msg", isStreaming: false).toStoredInfo()],
            forSessionId: "stale-session-2",
            serverId: serverId
        )

        let cacheDelegate = StorageBackedCacheDelegate(storage: storage)
        let serverViewModel = ServerViewModel(
            id: serverId,
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            workingDirectory: "/tmp",
            connectionManager: manager,
            getService: { manager.service },
            append: { _ in },
            logWire: { _, _ in },
            cacheDelegate: cacheDelegate,
            storage: storage
        )

        serverViewModel.updateAgentInfo(AgentProfile(
            id: nil, name: "test-agent", title: "Test", version: "1.0",
            description: nil, modes: [],
            capabilities: AgentCapabilityState(loadSession: false),
            verifications: []
        ))

        serverViewModel.fetchSessionList()
        serverViewModel.openSession("stale-session-2")

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(hasSentRequest(connection: connection, method: "session/load"),
                       "session/load must NOT be sent when agent doesn't support it")

        let messages = try XCTUnwrap(serverViewModel.currentSessionViewModel?.chatMessages)
        XCTAssertFalse(messages.isEmpty, "Cached messages should still be shown")
    }

    func testSendPromptPreflightCallsSessionLoadForNonMaterializedSession() async throws {
        // Simulates: session is active but not materialized (e.g., openSession
        // didn't fire load, or connection was lost and restored). sendPrompt
        // should call session/load before session/prompt.
        let connection = RecordingWebSocketConnection()
        let provider = RecordingWebSocketProvider(connection: connection)
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://localhost:1234")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let suiteName = "ServerViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.setServiceForTesting(service)

        Task {
            guard let initRequest = await self.waitForSentRequest(connection: connection, method: "initialize"),
                  let initId = initRequest["id"] as? Int else { return }
            try? self.enqueueResponse(id: initId, result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(true)
                ])
            ]), on: connection)
        }

        let initialized = await manager.initializeAndWait(
            payload: ACPInitializationPayload(clientName: "Agmente iOS", clientVersion: "0.1.0")
        )
        XCTAssertTrue(initialized)

        let serverId = UUID()
        let storage = SessionStorage.inMemory()
        storage.saveServer(makeStoredServer(id: serverId))

        let serverViewModel = ServerViewModel(
            id: serverId,
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            workingDirectory: "/tmp",
            connectionManager: manager,
            getService: { manager.service },
            append: { _ in },
            logWire: { _, _ in },
            cacheDelegate: TestCacheDelegate(),
            storage: storage
        )

        serverViewModel.updateAgentInfo(AgentProfile(
            id: nil, name: "test-agent", title: "Test", version: "1.0",
            description: nil, modes: [],
            capabilities: AgentCapabilityState(loadSession: true),
            verifications: []
        ))

        // Manually set active session without materializing it — simulates
        // a session that was set up without going through the normal create flow.
        serverViewModel.setActiveSession("orphaned-session-1")
        XCTAssertFalse(manager.isSessionMaterialized("orphaned-session-1"))

        // Enqueue responses for session/load then session/prompt
        Task {
            guard let loadRequest = await self.waitForSentRequest(connection: connection, method: "session/load"),
                  let loadId = loadRequest["id"] as? Int else { return }
            try? self.enqueueResponse(id: loadId, result: .object([:]), on: connection)

            guard let promptRequest = await self.waitForSentRequest(connection: connection, method: "session/prompt"),
                  let promptId = promptRequest["id"] as? Int else { return }
            try? self.enqueueResponse(
                id: promptId,
                result: .object(["stopReason": .string("end_turn")]),
                on: connection
            )
        }

        serverViewModel.sendPrompt(promptText: "hello after restart", images: [])

        // Wait for both requests
        let loadReq = await waitForSentRequest(connection: connection, method: "session/load")
        let promptReq = await waitForSentRequest(connection: connection, method: "session/prompt")
        XCTAssertNotNil(loadReq, "session/load preflight should fire for non-materialized session")
        XCTAssertNotNil(promptReq, "session/prompt should follow session/load")

        // Verify ordering: session/load comes before session/prompt
        let allRequests = sentRequests(connection: connection)
        let methods = allRequests.compactMap { $0["method"] as? String }
        if let loadIdx = methods.firstIndex(of: "session/load"),
           let promptIdx = methods.firstIndex(of: "session/prompt") {
            XCTAssertLessThan(loadIdx, promptIdx,
                              "session/load must be sent before session/prompt")
        }

        // Verify session is now materialized
        XCTAssertTrue(manager.isSessionMaterialized("orphaned-session-1"))
    }

    func testReconnectRecoveryLoadsSelectedACPSessionAndClearsStaleState() async throws {
        let connection = RecordingWebSocketConnection()
        let provider = RecordingWebSocketProvider(connection: connection)
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://localhost:1234")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let suiteName = "ServerViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.setServiceForTesting(service)

        Task {
            guard let initRequest = await self.waitForSentRequest(connection: connection, method: "initialize"),
                  let initId = initRequest["id"] as? Int else { return }
            try? self.enqueueResponse(id: initId, result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(true)
                ])
            ]), on: connection)
        }

        let initialized = await manager.initializeAndWait(
            payload: ACPInitializationPayload(clientName: "Agmente iOS", clientVersion: "0.1.0")
        )
        XCTAssertTrue(initialized)

        let serverViewModel = ServerViewModel(
            id: UUID(),
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            workingDirectory: "/tmp",
            connectionManager: manager,
            getService: { manager.service },
            append: { _ in },
            logWire: { _, _ in },
            cacheDelegate: TestCacheDelegate(),
            storage: SessionStorage.inMemory()
        )
        serverViewModel.updateAgentInfo(AgentProfile(
            id: nil, name: "test-agent", title: "Test", version: "1.0",
            description: nil, modes: [],
            capabilities: AgentCapabilityState(loadSession: true),
            verifications: []
        ))
        serverViewModel.setActiveSession("recoverable-session")
        manager.resetSessionState()

        serverViewModel.markSelectedSessionStaleAfterReconnect()
        XCTAssertTrue(serverViewModel.isCurrentSessionStale)
        XCTAssertFalse(manager.isSessionMaterialized("recoverable-session"))

        Task {
            guard let loadRequest = await self.waitForSentRequest(connection: connection, method: "session/load"),
                  let loadId = loadRequest["id"] as? Int else { return }
            try? self.enqueueResponse(id: loadId, result: .object([:]), on: connection)
        }

        let recovered = await serverViewModel.recoverSelectedSessionAfterReconnect()

        XCTAssertTrue(recovered)
        XCTAssertFalse(serverViewModel.isCurrentSessionStale)
        XCTAssertFalse(serverViewModel.isCurrentSessionSyncing)
        XCTAssertFalse(serverViewModel.isCurrentSessionLocalOnly)
        XCTAssertTrue(manager.isSessionMaterialized("recoverable-session"))
        XCTAssertEqual(serverViewModel.lastLoadedSession, "recoverable-session")
        let loadRequest = await waitForSentRequest(connection: connection, method: "session/load")
        XCTAssertNotNil(loadRequest)
    }

    func testReconnectRecoveryKeepsCachedTranscriptVisibleWhileSessionLoadIsInFlight() async throws {
        let connection = RecordingWebSocketConnection()
        let provider = RecordingWebSocketProvider(connection: connection)
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://localhost:1234")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let suiteName = "ServerViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.setServiceForTesting(service)

        Task {
            guard let initRequest = await self.waitForSentRequest(connection: connection, method: "initialize"),
                  let initId = initRequest["id"] as? Int else { return }
            try? self.enqueueResponse(id: initId, result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(true)
                ])
            ]), on: connection)
        }

        let initialized = await manager.initializeAndWait(
            payload: ACPInitializationPayload(clientName: "Agmente iOS", clientVersion: "0.1.0")
        )
        XCTAssertTrue(initialized)

        let serverViewModel = ServerViewModel(
            id: UUID(),
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            workingDirectory: "/tmp",
            connectionManager: manager,
            getService: { manager.service },
            append: { _ in },
            logWire: { _, _ in },
            cacheDelegate: TestCacheDelegate(),
            storage: SessionStorage.inMemory()
        )
        serverViewModel.updateAgentInfo(AgentProfile(
            id: nil, name: "test-agent", title: "Test", version: "1.0",
            description: nil, modes: [],
            capabilities: AgentCapabilityState(loadSession: true),
            verifications: []
        ))
        serverViewModel.setActiveSession("visible-session")
        serverViewModel.currentSessionViewModel?.addUserMessage(content: "Still visible", images: [])
        manager.resetSessionState()
        serverViewModel.markSelectedSessionStaleAfterReconnect()

        let recoveryTask = Task { @MainActor in
            await serverViewModel.recoverSelectedSessionAfterReconnect()
        }

        guard let loadRequest = await waitForSentRequest(connection: connection, method: "session/load"),
              let loadId = loadRequest["id"] as? Int else {
            XCTFail("Expected session/load request")
            return
        }

        let inFlightMessages = try XCTUnwrap(serverViewModel.currentSessionViewModel?.chatMessages)
        XCTAssertEqual(inFlightMessages.count, 1)
        XCTAssertEqual(inFlightMessages.first?.content, "Still visible")

        try enqueueResponse(id: loadId, result: .object([:]), on: connection)
        let recovered = await recoveryTask.value

        XCTAssertTrue(recovered)
        XCTAssertEqual(serverViewModel.currentSessionViewModel?.chatMessages.first?.content, "Still visible")
    }

    func testReconnectRecoveryMarksSelectedACPSessionLocalOnlyWhenLoadUnsupported() async throws {
        let connection = RecordingWebSocketConnection()
        let provider = RecordingWebSocketProvider(connection: connection)
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://localhost:1234")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let suiteName = "ServerViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.setServiceForTesting(service)

        let serverViewModel = ServerViewModel(
            id: UUID(),
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            workingDirectory: "/tmp",
            connectionManager: manager,
            getService: { manager.service },
            append: { _ in },
            logWire: { _, _ in },
            cacheDelegate: TestCacheDelegate(),
            storage: SessionStorage.inMemory()
        )
        serverViewModel.updateAgentInfo(AgentProfile(
            id: nil, name: "test-agent", title: "Test", version: "1.0",
            description: nil, modes: [],
            capabilities: AgentCapabilityState(loadSession: false),
            verifications: []
        ))
        serverViewModel.setActiveSession("local-only-session")
        serverViewModel.markSelectedSessionStaleAfterReconnect()

        let recovered = await serverViewModel.recoverSelectedSessionAfterReconnect()

        XCTAssertTrue(recovered)
        XCTAssertFalse(serverViewModel.isCurrentSessionStale)
        XCTAssertFalse(serverViewModel.isCurrentSessionSyncing)
        XCTAssertTrue(serverViewModel.isCurrentSessionLocalOnly)
        XCTAssertFalse(hasSentRequest(connection: connection, method: "session/load"))
    }
}
