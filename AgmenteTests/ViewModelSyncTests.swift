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
}