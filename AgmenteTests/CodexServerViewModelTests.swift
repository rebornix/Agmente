import XCTest
import ACP
@testable import Agmente
import ACPClient

/// Tests for CodexServerViewModel functionality.
@MainActor
final class CodexServerViewModelTests: XCTestCase {

    // MARK: - Test Infrastructure

    private func makeModel() -> AppViewModel {
        let suiteName = "CodexServerViewModelTests.\(UUID().uuidString)"
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

    // MARK: - ViewModel Switch Tests

    /// Test that ServerViewModel is switched to CodexServerViewModel after Codex initialize.
    func testServerViewModel_SwitchesToCodexAfterInitialize() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        // Initially should be a regular ServerViewModel
        XCTAssertNotNil(model.selectedServerViewModel, "Should start with ServerViewModel")
        XCTAssertNil(model.selectedCodexServerViewModel, "Should not have CodexServerViewModel initially")

        // Send initialize request
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)

        // Receive Codex initialize response (userAgent indicates Codex)
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: result))
        model.acpService(service, didReceiveMessage: response)

        // Should have switched to CodexServerViewModel
        XCTAssertNil(model.selectedServerViewModel, "Should no longer have ServerViewModel")
        XCTAssertNotNil(model.selectedCodexServerViewModel, "Should have CodexServerViewModel after Codex init")
    }

    /// Test that ACP server does not switch to CodexServerViewModel.
    func testServerViewModel_StaysACPForACPInitialize() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        // Send initialize request
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)

        // Receive ACP initialize response (no userAgent)
        let result: ACP.Value = .object([
            "protocolVersion": .number(1),
            "agentInfo": .object([
                "name": .string("acp-agent"),
            ]),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: result))
        model.acpService(service, didReceiveMessage: response)

        // Should still be ServerViewModel
        XCTAssertNotNil(model.selectedServerViewModel, "Should still have ServerViewModel for ACP")
        XCTAssertNil(model.selectedCodexServerViewModel, "Should not have CodexServerViewModel for ACP")
    }

    /// Test that agentInfo is synced to CodexServerViewModel after switch.
    func testAgentInfo_SyncedToCodexServerViewModelAfterSwitch() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        // Send initialize request
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)

        // Receive Codex initialize response
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: result))
        model.acpService(service, didReceiveMessage: response)

        // Verify agentInfo was synced to CodexServerViewModel
        let codexVM = model.selectedCodexServerViewModel
        XCTAssertNotNil(codexVM?.agentInfo, "CodexServerViewModel should have agentInfo")
        XCTAssertEqual(codexVM?.agentInfo?.name, "codex-app-server")
        XCTAssertEqual(codexVM?.agentInfo?.description, "codex/1.0.0")
    }

    // MARK: - CodexServerViewModel Behavior Tests

    /// Test that CodexServerViewModel isPendingSession is always false.
    func testCodexServerViewModel_IsPendingSessionAlwaysFalse() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        // Switch to Codex
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
        ])
        model.acpService(service, didReceiveMessage: .response(ACP.AnyResponse(id: .int(1), result: result)))

        let codexVM = model.selectedCodexServerViewModel
        XCTAssertNotNil(codexVM)

        // isPendingSession should always be false for Codex (threads are created immediately)
        XCTAssertFalse(codexVM?.isPendingSession ?? true, "Codex should never have pending sessions")
    }

    /// Test that selectedServerViewModelAny works for both ViewModel types.
    func testSelectedServerViewModelAny_WorksForBothTypes() {
        let model = makeModel()
        addServer(to: model)

        // Initially should work with ServerViewModel
        XCTAssertNotNil(model.selectedServerViewModelAny, "Should return view model initially")
        XCTAssertEqual(model.selectedServerViewModelAny?.name, "Local")

        // Switch to Codex
        let service = makeService()
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
        ])
        model.acpService(service, didReceiveMessage: .response(ACP.AnyResponse(id: .int(1), result: result)))

        // Should still work with CodexServerViewModel
        XCTAssertNotNil(model.selectedServerViewModelAny, "Should return view model after switch")
        XCTAssertEqual(model.selectedServerViewModelAny?.name, "Local")
    }

    // MARK: - Session Management Tests

    /// Test that ACP session summaries are not migrated when switching to CodexServerViewModel.
    func testSessionSummaries_NotMigratedOnSwitch() async {
        let model = makeModel()
        addServer(to: model)

        // Add some session summaries to the initial ServerViewModel
        let serverVM = model.selectedServerViewModel
        let testSummaries = [
            SessionSummary(id: "session-1", title: "Test 1", cwd: "/test", updatedAt: Date()),
            SessionSummary(id: "session-2", title: "Test 2", cwd: "/test2", updatedAt: Date()),
        ]
        serverVM?.sessionSummaries = testSummaries

        // Switch to Codex
        let service = makeService()
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
        ])
        model.acpService(service, didReceiveMessage: .response(ACP.AnyResponse(id: .int(1), result: result)))
        await Task.yield()

        // Session summaries should not be migrated
        let codexVM = model.selectedCodexServerViewModel
        XCTAssertEqual(codexVM?.sessionSummaries.count, 0, "Codex should start with a fresh session list")
    }

    /// Test that setActiveSession works on CodexServerViewModel.
    func testCodexServerViewModel_SetActiveSession() {
        let model = makeModel()
        addServer(to: model)

        // Switch to Codex
        let service = makeService()
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
        ])
        model.acpService(service, didReceiveMessage: .response(ACP.AnyResponse(id: .int(1), result: result)))

        let codexVM = model.selectedCodexServerViewModel
        XCTAssertNotNil(codexVM)

        // Set active session
        codexVM?.setActiveSession("thread-123", cwd: "/workspace", modes: nil)

        // Verify session was set
        XCTAssertEqual(codexVM?.sessionId, "thread-123")
        XCTAssertEqual(codexVM?.selectedSessionId, "thread-123")
    }

    /// Test that openSession on CodexServerViewModel just sets active (no session/load).
    func testCodexServerViewModel_OpenSessionSetsActive() async {
        let model = makeModel()
        addServer(to: model)

        // Switch to Codex
        let service = makeService()
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
        ])
        model.acpService(service, didReceiveMessage: .response(ACP.AnyResponse(id: .int(1), result: result)))

        let codexVM = model.selectedCodexServerViewModel
        XCTAssertNotNil(codexVM)

        // Add a session to summaries
        codexVM?.sessionSummaries = [
            SessionSummary(id: "thread-456", title: "Test Thread", cwd: nil, updatedAt: Date())
        ]

        // Open the session
        codexVM?.openSession("thread-456")
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Verify session was activated (no pending load)
        XCTAssertEqual(codexVM?.sessionId, "thread-456")
        XCTAssertNil(codexVM?.pendingSessionLoad, "Codex should not have pending session load")
    }
}