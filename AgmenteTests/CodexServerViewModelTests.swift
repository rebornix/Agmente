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
        XCTAssertEqual(codexVM?.agentInfo?.version, "1.0.0")
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

    func testCodexServerViewModel_DefaultPermissionPreset() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
        ])
        model.acpService(service, didReceiveMessage: .response(ACP.AnyResponse(id: .int(1), result: result)))

        guard let codexVM = model.selectedCodexServerViewModel else {
            XCTFail("Expected CodexServerViewModel")
            return
        }

        XCTAssertEqual(codexVM.permissionPreset, .defaultPermissions)
        XCTAssertEqual(codexVM.permissionPreset.displayName, "Default permissions")
        XCTAssertEqual(codexVM.permissionPreset.turnApprovalPolicy, "on-request")
        XCTAssertEqual(codexVM.permissionPreset.turnSandboxPolicy, .object(["type": .string("workspaceWrite")]))
    }

    func testCodexPermissionPreset_FullAccessMapsToDangerousTurnOverrides() {
        let preset = CodexServerViewModel.PermissionPreset.fullAccess

        XCTAssertEqual(preset.displayName, "Full access")
        XCTAssertEqual(preset.turnApprovalPolicy, "never")
        XCTAssertEqual(preset.turnSandboxPolicy, .object(["type": .string("dangerFullAccess")]))
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

    /// Streaming state should follow turn lifecycle notifications so the UI can toggle stop/send reliably.
    func testCodexServerViewModel_StreamingTracksTurnLifecycle() {
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

        guard let codexVM = model.selectedCodexServerViewModel else {
            XCTFail("Expected CodexServerViewModel")
            return
        }

        codexVM.setActiveSession("thread-789", cwd: "/workspace", modes: nil)
        XCTAssertFalse(codexVM.isStreaming, "Thread should not stream before turn start")

        let turnStarted = JSONRPCMessage.notification(
            JSONRPCNotification(
                method: "turn/started",
                params: .object([
                    "threadId": .string("thread-789"),
                    "turn": .object(["id": .string("turn-1")]),
                ])
            )
        )
        codexVM.handleCodexMessage(turnStarted)

        XCTAssertTrue(codexVM.isStreaming, "turn/started should enable streaming state")
        XCTAssertEqual(codexVM.currentSessionViewModel?.chatMessages.last?.isStreaming, true)

        let turnCompleted = JSONRPCMessage.notification(
            JSONRPCNotification(
                method: "turn/completed",
                params: .object([
                    "threadId": .string("thread-789"),
                    "turn": .object(["id": .string("turn-1")]),
                ])
            )
        )
        codexVM.handleCodexMessage(turnCompleted)

        XCTAssertFalse(codexVM.isStreaming, "turn/completed should clear streaming state")
        XCTAssertEqual(codexVM.currentSessionViewModel?.chatMessages.last?.isStreaming, false)
    }

    /// Reconnect races can leave a stale active turn ID; incoming deltas should realign instead of being dropped.
    func testCodexServerViewModel_ItemDeltaRealignsStaleActiveTurn() {
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

        guard let codexVM = model.selectedCodexServerViewModel else {
            XCTFail("Expected CodexServerViewModel")
            return
        }

        codexVM.setActiveSession("thread-101", cwd: "/workspace", modes: nil)

        // Start with a stale active turn ID.
        let oldTurnStarted = JSONRPCMessage.notification(
            JSONRPCNotification(
                method: "turn/started",
                params: .object([
                    "threadId": .string("thread-101"),
                    "turn": .object(["id": .string("turn-old")]),
                ])
            )
        )
        codexVM.handleCodexMessage(oldTurnStarted)

        // Incoming delta arrives for a newer turn; this should be applied (not dropped).
        let delta = JSONRPCMessage.notification(
            JSONRPCNotification(
                method: "item/agentMessage/delta",
                params: .object([
                    "threadId": .string("thread-101"),
                    "turnId": .string("turn-new"),
                    "delta": .string("hello"),
                ])
            )
        )
        codexVM.handleCodexMessage(delta)

        XCTAssertTrue(codexVM.currentSessionViewModel?.chatMessages.last?.content.contains("hello") == true)
        XCTAssertTrue(codexVM.isStreaming, "Delta should keep session streaming")

        // Completion for the new turn should now be accepted and end streaming.
        let newTurnCompleted = JSONRPCMessage.notification(
            JSONRPCNotification(
                method: "turn/completed",
                params: .object([
                    "threadId": .string("thread-101"),
                    "turn": .object(["id": .string("turn-new")]),
                ])
            )
        )
        codexVM.handleCodexMessage(newTurnCompleted)

        XCTAssertFalse(codexVM.isStreaming)
    }

    func testCodexServerViewModel_PlanDeltaAndPlanUpdatedRenderPlanSegment() {
        let model = makeModel()
        addServer(to: model)

        let service = makeService()
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
        ])
        model.acpService(service, didReceiveMessage: .response(ACP.AnyResponse(id: .int(1), result: result)))

        guard let codexVM = model.selectedCodexServerViewModel else {
            XCTFail("Expected CodexServerViewModel")
            return
        }
        codexVM.setActiveSession("thread-plan", cwd: "/workspace", modes: nil)

        let planDelta = JSONRPCMessage.notification(
            JSONRPCNotification(
                method: "item/plan/delta",
                params: .object([
                    "threadId": .string("thread-plan"),
                    "turnId": .string("turn-plan-1"),
                    "delta": .string("Planning"),
                ])
            )
        )
        codexVM.handleCodexMessage(planDelta)

        guard let deltaMessage = codexVM.currentSessionViewModel?.chatMessages.last else {
            XCTFail("Expected assistant message after plan delta")
            return
        }
        XCTAssertEqual(deltaMessage.role, .assistant)
        XCTAssertTrue(deltaMessage.isStreaming)
        XCTAssertEqual(deltaMessage.segments.last?.kind, .plan)
        XCTAssertTrue(deltaMessage.segments.last?.text.contains("Planning") == true)

        let planUpdated = JSONRPCMessage.notification(
            JSONRPCNotification(
                method: "turn/plan/updated",
                params: .object([
                    "threadId": .string("thread-plan"),
                    "turnId": .string("turn-plan-1"),
                    "explanation": .string("Implementation plan"),
                    "plan": .array([
                        .object([
                            "step": .string("Step one"),
                            "status": .string("completed"),
                        ]),
                        .object([
                            "step": .string("Step two"),
                            "description": .string("Run migration"),
                            "status": .string("in_progress"),
                        ]),
                    ]),
                ])
            )
        )
        codexVM.handleCodexMessage(planUpdated)

        guard let updatedMessage = codexVM.currentSessionViewModel?.chatMessages.last else {
            XCTFail("Expected assistant message after plan update")
            return
        }
        guard let planSegment = updatedMessage.segments.last else {
            XCTFail("Expected plan segment")
            return
        }
        XCTAssertEqual(planSegment.kind, .plan)
        XCTAssertEqual(
            planSegment.text,
            "Implementation plan\n\n- Step one (completed)\n- Step two: Run migration (in_progress)"
        )
    }

    func testCodexServerViewModel_ItemCompletedMessageWithProposedPlanBecomesPlanSegment() {
        let model = makeModel()
        addServer(to: model)

        let service = makeService()
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
        ])
        model.acpService(service, didReceiveMessage: .response(ACP.AnyResponse(id: .int(1), result: result)))

        guard let codexVM = model.selectedCodexServerViewModel else {
            XCTFail("Expected CodexServerViewModel")
            return
        }
        codexVM.setActiveSession("thread-plan-2", cwd: "/workspace", modes: nil)

        let completed = JSONRPCMessage.notification(
            JSONRPCNotification(
                method: "item/completed",
                params: .object([
                    "threadId": .string("thread-plan-2"),
                    "turnId": .string("turn-plan-2"),
                    "item": .object([
                        "type": .string("message"),
                        "role": .string("assistant"),
                        "content": .array([
                            .object([
                                "type": .string("output_text"),
                                "text": .string("<proposed_plan>\n1. backup data\n2. drop tables\n</proposed_plan>"),
                            ]),
                        ]),
                    ]),
                ])
            )
        )
        codexVM.handleCodexMessage(completed)

        guard let message = codexVM.currentSessionViewModel?.chatMessages.last else {
            XCTFail("Expected assistant message")
            return
        }
        guard let planSegment = message.segments.last else {
            XCTFail("Expected plan segment")
            return
        }
        XCTAssertEqual(planSegment.kind, .plan)
        XCTAssertEqual(planSegment.text, "1. backup data\n2. drop tables")
        XCTAssertFalse(message.content.contains("<proposed_plan>"))
    }

    func testCodexServerViewModel_IgnoresRawPlanDeltaWhenStructuredPlanDeltaArrives() {
        let model = makeModel()
        addServer(to: model)

        let service = makeService()
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
        ])
        model.acpService(service, didReceiveMessage: .response(ACP.AnyResponse(id: .int(1), result: result)))

        guard let codexVM = model.selectedCodexServerViewModel else {
            XCTFail("Expected CodexServerViewModel")
            return
        }
        codexVM.setActiveSession("thread-plan-raw", cwd: "/workspace", modes: nil)

        let rawPlanDelta = JSONRPCMessage.notification(
            JSONRPCNotification(
                method: "codex/event/plan_delta",
                params: .object([
                    "conversationId": .string("thread-plan-raw"),
                    "id": .string("turn-plan-raw-1"),
                    "msg": .object([
                        "thread_id": .string("thread-plan-raw"),
                        "turn_id": .string("turn-plan-raw-1"),
                        "item_id": .string("turn-plan-raw-1-plan"),
                        "delta": .string("A"),
                    ]),
                ])
            )
        )
        codexVM.handleCodexMessage(rawPlanDelta)

        let structuredPlanDelta = JSONRPCMessage.notification(
            JSONRPCNotification(
                method: "item/plan/delta",
                params: .object([
                    "threadId": .string("thread-plan-raw"),
                    "turnId": .string("turn-plan-raw-1"),
                    "itemId": .string("turn-plan-raw-1-plan"),
                    "delta": .string("A"),
                ])
            )
        )
        codexVM.handleCodexMessage(structuredPlanDelta)

        guard let message = codexVM.currentSessionViewModel?.chatMessages.last else {
            XCTFail("Expected assistant message")
            return
        }
        guard let planSegment = message.segments.last else {
            XCTFail("Expected plan segment")
            return
        }
        XCTAssertEqual(planSegment.kind, .plan)
        XCTAssertEqual(planSegment.text, "A")
    }

    func testCodexServerViewModel_PlanDeltaPreservesWhitespaceAndNewlines() {
        let model = makeModel()
        addServer(to: model)

        let service = makeService()
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
        ])
        model.acpService(service, didReceiveMessage: .response(ACP.AnyResponse(id: .int(1), result: result)))

        guard let codexVM = model.selectedCodexServerViewModel else {
            XCTFail("Expected CodexServerViewModel")
            return
        }
        codexVM.setActiveSession("thread-plan-spacing", cwd: "/workspace", modes: nil)

        let deltas = ["# Plan", "\n\n", "1. first", "\n", "2.", " ", "second"]
        for delta in deltas {
            let planDelta = JSONRPCMessage.notification(
                JSONRPCNotification(
                    method: "item/plan/delta",
                    params: .object([
                        "threadId": .string("thread-plan-spacing"),
                        "turnId": .string("turn-plan-spacing-1"),
                        "itemId": .string("turn-plan-spacing-1-plan"),
                        "delta": .string(delta),
                    ])
                )
            )
            codexVM.handleCodexMessage(planDelta)
        }

        guard let message = codexVM.currentSessionViewModel?.chatMessages.last else {
            XCTFail("Expected assistant message")
            return
        }
        guard let planSegment = message.segments.last else {
            XCTFail("Expected plan segment")
            return
        }
        XCTAssertEqual(planSegment.kind, .plan)
        XCTAssertEqual(planSegment.text, "# Plan\n\n1. first\n2. second")
    }
}
