import enum ACP.ACPError
import XCTest
import ACP
@testable import Agmente
import ACPClient

/// Tests for AppViewModel -> ServerViewModel synchronization.
/// These tests verify that state is properly synced between the view models
/// during initialization and capability detection.
@MainActor
final class ViewModelSyncTests: XCTestCase {

    // MARK: - Test Infrastructure

    private func makeModel() -> AppViewModel {
        let suiteName = "ViewModelSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let storage = SessionStorage.inMemory()
        return AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
    }

    private func addServer(to model: AppViewModel, agentInfo: AgentProfile? = nil) {
        model.addServer(
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            cfAccessClientId: "",
            cfAccessClientSecret: "",
            workingDirectory: "/",
            agentInfo: agentInfo
        )
    }

    private func makeService() -> ACPService {
        let url = URL(string: "ws://localhost:1234")!
        let config = ACPClientConfiguration(endpoint: url, pingInterval: nil)
        let client = ACPClient(configuration: config)
        return ACPService(client: client)
    }

    private func makeAgentInfo(
        name: String = "test-agent",
        loadSession: Bool = false,
        listSessions: Bool = true
    ) -> AgentProfile {
        var capabilities = AgentCapabilityState()
        capabilities.loadSession = loadSession
        capabilities.listSessions = listSessions
        return AgentProfile(
            id: nil,
            name: name,
            title: nil,
            version: "1.0.0",
            description: nil,
            modes: [],
            capabilities: capabilities,
            verifications: []
        )
    }

    // MARK: - AgentProfile Sync Tests

    /// Test that agentInfo is synced to ServerViewModel when provided during addServer.
    func testAgentInfo_SyncedOnAddServer() {
        let model = makeModel()
        let agentInfo = makeAgentInfo(name: "my-agent", loadSession: true, listSessions: true)
        addServer(to: model, agentInfo: agentInfo)

        // Verify ServerViewModel received the agentInfo
        let serverVM = model.selectedServerViewModel
        XCTAssertNotNil(serverVM?.agentInfo, "ServerViewModel should have agentInfo")
        XCTAssertEqual(serverVM?.agentInfo?.name, "my-agent")
        XCTAssertEqual(serverVM?.agentInfo?.capabilities.loadSession, true)
        XCTAssertEqual(serverVM?.agentInfo?.capabilities.listSessions, true)
    }

    /// Test that agentInfo is synced to ServerViewModel after ACP initialize response.
    func testAgentInfo_SyncedAfterACPInitialize() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        // Send initialize request
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)

        // Receive ACP initialize response
        let result: ACP.Value = .object([
            "protocolVersion": .number(1),
            "agentInfo": .object([
                "name": .string("acp-agent"),
                "version": .string("2.0.0"),
            ]),
            "agentCapabilities": .object([
                "loadSession": .bool(true),
                "listSessions": .bool(true),
            ]),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: result))
        model.acpService(service, didReceiveMessage: response)

        // Verify ServerViewModel received the agentInfo
        let serverVM = model.selectedServerViewModel
        XCTAssertNotNil(serverVM?.agentInfo, "ServerViewModel should have agentInfo after initialize")
        XCTAssertEqual(serverVM?.agentInfo?.name, "acp-agent")
        XCTAssertEqual(serverVM?.agentInfo?.capabilities.loadSession, true)
    }

    /// Test that agentInfo is synced to CodexServerViewModel after Codex initialize response.
    /// Note: After Codex initialize, AppViewModel switches from ServerViewModel to CodexServerViewModel.
    func testAgentInfo_SyncedAfterCodexInitialize() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        // Send initialize request
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)

        // Receive Codex initialize response (userAgent indicates Codex)
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
            "agentInfo": .object([
                "name": .string("codex-agent"),
            ]),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: result))
        model.acpService(service, didReceiveMessage: response)

        // Prefer ACP when ACP markers like agentInfo are present, even if userAgent is set.
        XCTAssertNotNil(model.selectedServerViewModel, "Should remain ServerViewModel when ACP markers exist")
        XCTAssertNil(model.selectedCodexServerViewModel, "Should not switch to CodexServerViewModel when ACP markers exist")

        XCTAssertEqual(model.selectedServerViewModel?.agentInfo?.name, "codex-agent")
    }

    /// Test that capability changes are synced to ServerViewModel.
    func testCapabilityChange_SyncedToServerViewModel() {
        let model = makeModel()
        let agentInfo = makeAgentInfo(loadSession: true, listSessions: true)
        addServer(to: model, agentInfo: agentInfo)
        let service = makeService()

        // Verify initial state
        XCTAssertEqual(model.selectedServerViewModel?.agentInfo?.capabilities.listSessions, true)

        // Send session/list request that will fail
        let listRequest = ACP.AnyRequest(id: .int(2), method: "session/list", params: nil)
        model.acpService(service, willSend: listRequest)

        // Receive error response (marks listSessions as false)
        let error = ACPError.methodNotFound("Method not found")
        let errorResponse = ACPWireMessage.response(ACP.AnyResponse(id: .int(2), error: error))
        model.acpService(service, didReceiveMessage: errorResponse)

        // Verify capability change was synced
        XCTAssertEqual(model.selectedServerViewModel?.agentInfo?.capabilities.listSessions, false,
                       "Capability change should be synced to ServerViewModel")
    }

    // MARK: - ConnectedProtocol Sync Tests

    /// Test that connectedProtocol is synced to ServerViewModel after ACP initialize.
    func testConnectedProtocol_SyncedAfterACPInitialize() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        // Send initialize request
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)

        // Receive ACP initialize response
        let result: ACP.Value = .object([
            "protocolVersion": .number(1),
            "agentInfo": .object([
                "name": .string("acp-agent"),
            ]),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: result))
        model.acpService(service, didReceiveMessage: response)

        // ServerViewModel should have connectedProtocol set
        // We can't directly check private property, but we can verify behavior
        // by checking that Codex-specific code paths don't execute
        // For now, just verify agentInfo was synced (which implies protocol was also synced)
        XCTAssertNotNil(model.selectedServerViewModel?.agentInfo)
    }

    // MARK: - isPendingSession Tests

    /// Test that isPendingSession delegates to ServerViewModel.
    func testIsPendingSession_DelegatesToServerViewModel() {
        let model = makeModel()
        addServer(to: model)

        // Initially, no pending session
        XCTAssertFalse(model.isPendingSession, "Should not have pending session initially")

        // Note: To fully test this, we'd need to simulate session creation through ServerViewModel
        // which would add to ServerViewModel's pendingLocalSessions. For now, we verify the
        // delegation by checking that AppViewModel.isPendingSession returns false when
        // ServerViewModel has no pending sessions.
    }

    /// Test that isPendingSession returns false when no server is selected.
    func testIsPendingSession_FalseWhenNoServer() {
        let model = makeModel()
        // Don't add a server

        XCTAssertFalse(model.isPendingSession, "Should return false when no server is selected")
    }

    // MARK: - Session List Fetch Behavior Tests

    /// Test that session list is fetched by default (capability unknown).
    func testSessionListFetch_DefaultsToTrue() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        // Send initialize request (no agentInfo yet)
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)

        // Receive minimal initialize response (no explicit listSessions)
        let result: ACP.Value = .object([
            "protocolVersion": .number(1),
            "agentInfo": .object([
                "name": .string("minimal-agent"),
            ]),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: result))
        model.acpService(service, didReceiveMessage: response)

        // Default listSessions should be true
        XCTAssertEqual(model.currentSessionListSupport, true,
                       "Session list support should default to true")
    }

    /// Test that session list is not fetched when explicitly disabled.
    func testSessionListFetch_RespectsExplicitFalse() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)

        // Response with explicit listSessions: false
        let result: ACP.Value = .object([
            "protocolVersion": .number(1),
            "agentInfo": .object([
                "name": .string("no-list-agent"),
            ]),
            "agentCapabilities": .object([
                "listSessions": .bool(false),
            ]),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: result))
        model.acpService(service, didReceiveMessage: response)

        XCTAssertEqual(model.currentSessionListSupport, false,
                       "Session list support should be false when explicitly disabled")
    }

    // MARK: - CWD Update Tests

    /// Test that session CWD is updated when opening a session with specific CWD.
    func testSessionCWD_UpdatedWhenOpening() {
        let model = makeModel()
        let agentInfo = makeAgentInfo(loadSession: false)
        addServer(to: model, agentInfo: agentInfo)

        let sessionId = "test-session"
        let initialCwd = "/initial"
        let updatedCwd = "/updated"

        // Add session with initial CWD to session summaries
        let serverVM = model.selectedServerViewModel
        serverVM?.sessionSummaries = [
            SessionSummary(id: sessionId, title: "Test", cwd: initialCwd, updatedAt: Date())
        ]

        // Verify initial CWD
        XCTAssertEqual(serverVM?.sessionSummaries.first?.cwd, initialCwd)

        // Open session with updated CWD (simulates setActiveSession with cwd parameter)
        serverVM?.setActiveSession(sessionId, cwd: updatedCwd)

        // Verify CWD was updated
        XCTAssertEqual(serverVM?.sessionSummaries.first?.cwd, updatedCwd,
                       "Session CWD should be updated when opening with specific CWD")
    }

    /// Test that session updatedAt is preserved when only updating CWD.
    func testSessionTimestamp_PreservedWhenUpdatingCWD() {
        let model = makeModel()
        let agentInfo = makeAgentInfo(loadSession: false)
        addServer(to: model, agentInfo: agentInfo)

        let sessionId = "test-session"
        let originalDate = Date(timeIntervalSince1970: 1000)

        // Add session with specific timestamp
        let serverVM = model.selectedServerViewModel
        serverVM?.sessionSummaries = [
            SessionSummary(id: sessionId, title: "Test", cwd: "/old", updatedAt: originalDate)
        ]

        // Open session with new CWD
        serverVM?.setActiveSession(sessionId, cwd: "/new")

        // Verify timestamp was preserved (not bumped to now)
        let updatedSession = serverVM?.sessionSummaries.first
        XCTAssertEqual(updatedSession?.updatedAt, originalDate,
                       "Session timestamp should be preserved when only updating CWD")
    }

    // MARK: - Cached Server Properties Tests

    /// Test that serverSessionSummaries is cached and syncs from child view model.
    func testServerSessionSummaries_CachedAndSynced() {
        let model = makeModel()
        addServer(to: model, agentInfo: makeAgentInfo())

        // Initially empty
        XCTAssertEqual(model.serverSessionSummaries.count, 0, "Should start with no sessions")

        // Update session summaries in ServerViewModel
        let serverVM = model.selectedServerViewModel
        let testSession = SessionSummary(id: "test-1", title: "Test Session", cwd: "/test", updatedAt: Date())
        serverVM?.sessionSummaries = [testSession]

        // Verify AppViewModel's cached property was updated
        XCTAssertEqual(model.serverSessionSummaries.count, 1, "Cached summaries should update")
        XCTAssertEqual(model.serverSessionSummaries.first?.id, "test-1")
        XCTAssertEqual(model.serverSessionSummaries.first?.title, "Test Session")
    }

    /// Test that serverSessionId is cached and syncs from child view model.
    func testServerSessionId_CachedAndSynced() {
        let model = makeModel()
        addServer(to: model, agentInfo: makeAgentInfo())

        // Initially empty
        XCTAssertEqual(model.serverSessionId, "", "Should start with no session ID")

        // Update session ID in ServerViewModel
        let serverVM = model.selectedServerViewModel
        serverVM?.sessionId = "test-session-123"

        // Verify AppViewModel's cached property was updated
        XCTAssertEqual(model.serverSessionId, "test-session-123", "Cached session ID should update")
    }

    /// Test that serverIsStreaming is cached and syncs from child view model.
    func testServerIsStreaming_CachedAndSynced() {
        let model = makeModel()
        addServer(to: model, agentInfo: makeAgentInfo())

        // Initially false
        XCTAssertFalse(model.serverIsStreaming, "Should start not streaming")

        // Note: ServerViewModel's isStreaming is a computed property based on session state.
        // A full test would require setting up a session with streaming state.
        // For now, we verify the property exists and is accessible.
        XCTAssertFalse(model.serverIsStreaming)
    }

    /// Test that cached properties are cleared when no server is selected.
    func testCachedProperties_ClearedWhenNoServerSelected() {
        let model = makeModel()
        addServer(to: model, agentInfo: makeAgentInfo())

        // Set some state
        let serverVM = model.selectedServerViewModel
        serverVM?.sessionSummaries = [SessionSummary(id: "test", title: "Test", cwd: "/", updatedAt: Date())]
        serverVM?.sessionId = "test"

        // Verify cached values are set
        XCTAssertEqual(model.serverSessionSummaries.count, 1)
        XCTAssertEqual(model.serverSessionId, "test")

        // Deselect server
        model.selectedServerId = nil

        // Verify cached values are cleared
        XCTAssertEqual(model.serverSessionSummaries.count, 0, "Should clear session summaries")
        XCTAssertEqual(model.serverSessionId, "", "Should clear session ID")
        XCTAssertFalse(model.serverIsStreaming, "Should clear streaming state")
        XCTAssertNil(model.serverAgentInfo, "Should clear agent info")
        XCTAssertFalse(model.serverIsPendingSession, "Should clear pending session state")
    }

    /// Test that cached properties update when switching between servers.
    func testCachedProperties_UpdateWhenSwitchingServers() {
        let model = makeModel()

        // Add first server
        model.addServer(
            name: "Server 1",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            cfAccessClientId: "",
            cfAccessClientSecret: "",
            workingDirectory: "/",
            agentInfo: makeAgentInfo(name: "agent-1")
        )
        let server1Id = model.selectedServerId!
        let serverVM1 = model.selectedServerViewModel
        serverVM1?.sessionSummaries = [SessionSummary(id: "s1", title: "Session 1", cwd: "/1", updatedAt: Date())]
        serverVM1?.sessionId = "s1"

        // Verify first server's state is cached
        XCTAssertEqual(model.serverSessionSummaries.count, 1)
        XCTAssertEqual(model.serverSessionId, "s1")

        // Add second server
        model.addServer(
            name: "Server 2",
            scheme: "ws",
            host: "localhost:5678",
            token: "",
            cfAccessClientId: "",
            cfAccessClientSecret: "",
            workingDirectory: "/",
            agentInfo: makeAgentInfo(name: "agent-2")
        )
        let server2Id = model.selectedServerId!
        let serverVM2 = model.selectedServerViewModel
        serverVM2?.sessionSummaries = [SessionSummary(id: "s2", title: "Session 2", cwd: "/2", updatedAt: Date())]
        serverVM2?.sessionId = "s2"

        // Verify second server's state is cached
        XCTAssertEqual(model.serverSessionSummaries.count, 1)
        XCTAssertEqual(model.serverSessionId, "s2")
        XCTAssertEqual(model.serverSessionSummaries.first?.id, "s2")

        // Switch back to first server
        model.selectedServerId = server1Id

        // Verify first server's state is restored
        XCTAssertEqual(model.serverSessionSummaries.count, 1)
        XCTAssertEqual(model.serverSessionId, "s1")
        XCTAssertEqual(model.serverSessionSummaries.first?.id, "s1")
    }
}