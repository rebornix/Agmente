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

    private func waitForSentText(
        connection: RecordingWebSocketConnection,
        matching predicate: @escaping (String) -> Bool,
        attempts: Int = 200
    ) async -> String? {
        for _ in 0..<attempts {
            if let text = connection.sentTextsSnapshot().first(where: predicate) {
                return text
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func extractRequest(from text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
            guard let initText = await self.waitForSentText(connection: connection, matching: { $0.contains("\"method\":\"initialize\"") }),
                  let initId = try? self.extractRequest(from: initText)["id"] as? Int else {
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
            guard let newSessionText = await self.waitForSentText(connection: connection, matching: { $0.contains("\"method\":\"session/new\"") }),
                  let newSessionRequest = try? self.extractRequest(from: newSessionText),
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

            guard let promptText = await self.waitForSentText(connection: connection, matching: { $0.contains("\"method\":\"session/prompt\"") }),
                  let promptRequest = try? self.extractRequest(from: promptText),
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

        let newSessionTextMaybe = await waitForSentText(
            connection: connection,
            matching: { $0.contains("\"method\":\"session/new\"") }
        )
        let newSessionText = try XCTUnwrap(newSessionTextMaybe)
        let newSessionRequest = try extractRequest(from: newSessionText)
        let newSessionParams = try XCTUnwrap(newSessionRequest["params"] as? [String: Any])
        XCTAssertEqual(newSessionParams["workingDirectory"] as? String, "/tmp/custom-project")

        let promptTextMaybe = await waitForSentText(
            connection: connection,
            matching: { $0.contains("\"method\":\"session/prompt\"") }
        )
        let promptText = try XCTUnwrap(promptTextMaybe)
        let promptRequest = try extractRequest(from: promptText)
        let promptParams = try XCTUnwrap(promptRequest["params"] as? [String: Any])
        XCTAssertEqual(promptParams["sessionId"] as? String, "server-session-123")
        XCTAssertNotEqual(promptParams["sessionId"] as? String, placeholderId)
        XCTAssertNil(connection.sentTextsSnapshot().first(where: { $0.contains("\"method\":\"session/load\"") }))

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
            guard let initText = await self.waitForSentText(connection: connection, matching: { $0.contains("\"method\":\"initialize\"") }),
                  let initId = try? self.extractRequest(from: initText)["id"] as? Int else {
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
            guard let newSessionText = await self.waitForSentText(connection: connection, matching: { $0.contains("\"method\":\"session/new\"") }),
                  let newSessionRequest = try? self.extractRequest(from: newSessionText),
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

        let newSessionRequestText = await waitForSentText(
            connection: connection,
            matching: { $0.contains("\"method\":\"session/new\"") }
        )
        _ = try XCTUnwrap(newSessionRequestText)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(serverViewModel.sessionId, "server-session-empty")
        XCTAssertEqual(serverViewModel.lastLoadedSession, "server-session-empty")
        XCTAssertTrue(manager.isSessionMaterialized("server-session-empty"))
        XCTAssertNil(connection.sentTextsSnapshot().first(where: { $0.contains("\"method\":\"session/load\"") }))

        serverViewModel.openSession("server-session-empty")

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(connection.sentTextsSnapshot().first(where: { $0.contains("\"method\":\"session/load\"") }))
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
            guard let initText = await self.waitForSentText(connection: connection, matching: { $0.contains("\"method\":\"initialize\"") }),
                  let initId = try? self.extractRequest(from: initText)["id"] as? Int else {
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
            guard let newSessionText = await self.waitForSentText(connection: connection, matching: { $0.contains("\"method\":\"session/new\"") }),
                  let newSessionRequest = try? self.extractRequest(from: newSessionText),
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

        let newSessionText = await waitForSentText(
            connection: connection,
            matching: { $0.contains("\"method\":\"session/new\"") }
        )
        _ = try XCTUnwrap(newSessionText)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(serverViewModel.sessionId, "")
        XCTAssertNil(serverViewModel.selectedSessionId)
        XCTAssertNil(connection.sentTextsSnapshot().first(where: { $0.contains("\"method\":\"session/prompt\"") }))
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
            guard let initText = await self.waitForSentText(connection: connection, matching: { $0.contains("\"method\":\"initialize\"") }),
                  let initId = try? self.extractRequest(from: initText)["id"] as? Int else {
                return
            }
            try? self.enqueueResponse(id: initId, result: .object(["status": .string("ok")]), on: connection)
        }

        XCTAssertTrue(await manager.initializeAndWait(
            payload: ACPInitializationPayload(clientName: "Agmente iOS", clientVersion: "0.1.0")
        ))

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
            guard let newSessionText = await self.waitForSentText(connection: connection, matching: { $0.contains("\"method\":\"session/new\"") }),
                  let newSessionRequest = try? self.extractRequest(from: newSessionText),
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

            guard let promptText = await self.waitForSentText(connection: connection, matching: { $0.contains("\"method\":\"session/prompt\"") }),
                  let promptRequest = try? self.extractRequest(from: promptText),
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
        storage.saveMessages(
            [ChatMessage(role: .user, content: "hello from copilot", isStreaming: false).toStoredInfo()],
            forSessionId: "copilot-session-1",
            serverId: serverId
        )

        let suiteName = "ServerViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)

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
            cacheDelegate: StorageBackedCacheDelegate(storage: storage),
            storage: storage
        )

        serverViewModel.fetchSessionList()

        XCTAssertEqual(serverViewModel.sessionSummaries.map(\.id), ["copilot-session-1"])

        serverViewModel.openSession("copilot-session-1")

        let restoredMessages = try XCTUnwrap(serverViewModel.currentSessionViewModel?.chatMessages)
        XCTAssertEqual(restoredMessages.first?.content, "hello from copilot")
    }
}
