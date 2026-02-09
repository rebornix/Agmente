import enum ACP.ACPError
import XCTest
import ACP
@testable import Agmente
import ACPClient

@MainActor
final class AgentViewModelTests: XCTestCase {
    private func makeModel() -> AppViewModel {
        let suiteName = "AgentViewModelTests.\(UUID().uuidString)"
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

    private func makeAgentInfo(name: String = "test-agent", title: String? = nil, version: String? = nil, loadSession: Bool = false) -> AgentProfile {
        var capabilities = AgentCapabilityState()
        capabilities.loadSession = loadSession
        capabilities.listSessions = true

        return AgentProfile(
            id: nil,
            name: name,
            title: title,
            version: version,
            description: nil,
            modes: [],
            capabilities: capabilities,
            verifications: []
        )
    }

    private func makeSessionUpdateMessage(sessionId: String, update: [String: ACP.Value]) -> ACPWireMessage {
        let params: ACP.Value = .object([
            "sessionId": .string(sessionId),
            "update": .object(update),
        ])
        return .notification(ACP.AnyMessage(method: "session/update", params: params))
    }

    private final class RecordingWebSocketConnection: WebSocketConnection, @unchecked Sendable {
        private var sentTexts: [String] = []
        private var events: [WebSocketEvent] = []
        private let autoCloseOnReceive: Bool
        private let lock = NSLock()

        init(autoCloseOnReceive: Bool = false) {
            self.autoCloseOnReceive = autoCloseOnReceive
        }

        func connect(headers: [String : String]) async throws {}

        func send(text: String) async throws {
            lock.lock()
            sentTexts.append(text)
            lock.unlock()
        }

        func receive() async throws -> WebSocketEvent {
            lock.lock()
            if !events.isEmpty {
                let event = events.removeFirst()
                lock.unlock()
                return event
            }
            lock.unlock()
            try? await Task.sleep(nanoseconds: 10_000_000)
            return autoCloseOnReceive ? .closed(WebSocketCloseReason(code: 1000)) : .connected
        }

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

        func close() async {}
        func ping() async throws {}
    }

    private struct RecordingWebSocketProvider: WebSocketProviding, @unchecked Sendable {
        let connection: RecordingWebSocketConnection

        func makeConnection(url: URL) -> WebSocketConnection {
            connection
        }
    }

    private func makeConnectedService(connection: RecordingWebSocketConnection) async throws -> ACPService {
        let url = URL(string: "ws://localhost:1234")!
        let config = ACPClientConfiguration(endpoint: url, pingInterval: nil, appendNewline: true)
        let provider = RecordingWebSocketProvider(connection: connection)
        let client = ACPClient(configuration: config, socketProvider: provider)
        let service = ACPService(client: client)
        try await service.connect()
        return service
    }

    func testCapabilitySupportReturnsNilBeforeInitialize() {
        let model = makeModel()
        addServer(to: model)

        // Before initialize, capability flags should be nil (unknown)
        XCTAssertNil(model.currentAgentInfo)
        XCTAssertNil(model.currentLoadSessionSupport)
        XCTAssertNil(model.currentSessionListSupport)
    }

    func testInitializeACPPopulatesAgentInfo() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        let request = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: request)

        let result: ACP.Value = .object([
            "protocolVersion": .number(1),
            "agentInfo": .object([
                "name": .string("test-agent"),
                "version": .string("0.1.0"),
            ]),
            "agentCapabilities": .object([
                "loadSession": .bool(true),
                "listSessions": .bool(true),
            ]),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: result))
        model.acpService(service, didReceiveMessage: response)

        XCTAssertEqual(model.currentAgentInfo?.name, "test-agent")
        XCTAssertEqual(model.initializationSummary, "test-agent v0.1.0 (initialized)")
        XCTAssertEqual(model.currentLoadSessionSupport, true)
        XCTAssertEqual(model.currentSessionListSupport, true)
    }

    func testInitializeCodexSetsCapabilities() {
        let model = makeModel()
        addServer(to: model, agentInfo: makeAgentInfo(loadSession: true))
        let service = makeService()

        let request = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: request)

        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: result))
        model.acpService(service, didReceiveMessage: response)

        XCTAssertEqual(model.currentAgentInfo?.name, "codex-app-server")
        XCTAssertEqual(model.initializationSummary, "Codex app-server (initialized)")
        XCTAssertEqual(model.currentLoadSessionSupport, false)
        XCTAssertTrue(model.currentSessionListSupport ?? false)
    }

    func testInitializePrefersACPWhenMarkersExist() {
        let model = makeModel()
        addServer(to: model, agentInfo: makeAgentInfo(loadSession: true))
        let service = makeService()

        let request = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: request)

        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
            "protocolVersion": .number(1),
            "agentInfo": .object([
                "name": .string("test-agent"),
                "version": .string("1.0.0"),
            ]),
            "agentCapabilities": .object([
                "loadSession": .bool(true),
            ]),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: result))
        model.acpService(service, didReceiveMessage: response)

        XCTAssertEqual(model.currentAgentInfo?.name, "test-agent")
        XCTAssertEqual(model.initializationSummary, "test-agent v1.0.0 (initialized)")
        XCTAssertEqual(model.currentLoadSessionSupport, true)
    }

    func testInitializeQwenCodeParsesModesAndCapabilities() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        let request = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: request)

        let result: ACP.Value = .object([
            "protocolVersion": .number(1),
            "agentInfo": .object([
                "name": .string("qwen-code"),
                "version": .string("0.4.0"),
                "title": .string("Qwen Code"),
            ]),
            "agentCapabilities": .object([
                "loadSession": .bool(true),
                "promptCapabilities": .object([
                    "image": .bool(true),
                    "audio": .bool(true),
                    "embeddedContext": .bool(true),
                ]),
            ]),
            "modes": .object([
                "currentModeId": .string("default"),
                "availableModes": .array([
                    .object(["id": .string("plan"), "name": .string("Plan"), "description": .string("Analyze only")]),
                    .object(["id": .string("default"), "name": .string("Default"), "description": .string("Require approval")]),
                    .object(["id": .string("auto-edit"), "name": .string("Auto Edit"), "description": .string("Auto approve edits")]),
                    .object(["id": .string("yolo"), "name": .string("YOLO"), "description": .string("Auto approve all")]),
                ]),
            ]),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: result))
        model.acpService(service, didReceiveMessage: response)

        XCTAssertEqual(model.currentAgentInfo?.name, "qwen-code")
        XCTAssertEqual(model.initializationSummary, "Qwen Code v0.4.0 (initialized)")
        XCTAssertEqual(model.currentAgentInfo?.capabilities.sessionListRequiresCwd, true)
        XCTAssertEqual(model.currentLoadSessionSupport, true)
        XCTAssertEqual(model.availableModes.count, 4)
        
        // Open a session to verify default mode is applied
        model.openSession("test-session")
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.currentModeId, "default")
    }

    func testInitializeDefaultsPromptCapabilitiesToFalse() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        let request = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: request)

        let result: ACP.Value = .object([
            "protocolVersion": .number(1),
            "agentInfo": .object([
                "name": .string("test-agent"),
                "version": .string("1.0.0"),
            ]),
            "agentCapabilities": .object([
                "loadSession": .bool(true),
            ]),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: result))
        model.acpService(service, didReceiveMessage: response)

        XCTAssertEqual(model.currentAgentInfo?.capabilities.promptCapabilities.audio, false)
        XCTAssertEqual(model.currentAgentInfo?.capabilities.promptCapabilities.image, false)
        XCTAssertEqual(model.currentAgentInfo?.capabilities.promptCapabilities.embeddedContext, false)
    }

    func testSessionListResponseUpdatesSummaries() {
        let model = makeModel()
        addServer(to: model, agentInfo: makeAgentInfo(loadSession: true))
        let service = makeService()

        let request = ACP.AnyRequest(id: .int(2), method: "session/list", params: nil)
        model.acpService(service, willSend: request)

        let result: ACP.Value = .object([
            "sessions": .array([
                .object([
                    "sessionId": .string("sess_1"),
                    "title": .string("Hello"),
                    "cwd": .string("/tmp"),
                    "updatedAt": .string("2025-01-01T00:00:00Z"),
                ]),
            ]),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(2), result: result))
        model.acpService(service, didReceiveMessage: response)

        XCTAssertEqual(model.selectedServerViewModel?.sessionSummaries.count, 1)
        let summary = model.selectedServerViewModel?.sessionSummaries[0]
        XCTAssertEqual(summary?.id, "sess_1")
        XCTAssertEqual(summary?.title, "Hello")
        XCTAssertEqual(summary?.cwd, "/tmp")
    }

    func testSessionListSuccessMarksSupportTrue() {
        let model = makeModel()
        addServer(to: model, agentInfo: makeAgentInfo(loadSession: true))
        let service = makeService()

        let request = ACP.AnyRequest(id: .int(10), method: "session/list", params: nil)
        model.acpService(service, willSend: request)

        let result: ACP.Value = .object([
            "items": .array([
                .object(["sessionId": .string("sess_1")]),
            ]),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(10), result: result))
        model.acpService(service, didReceiveMessage: response)

        XCTAssertEqual(model.currentSessionListSupport, true)
    }

    func testSessionListErrorMarksSupportFalse() {
        let model = makeModel()
        addServer(to: model, agentInfo: makeAgentInfo(loadSession: true))
        let service = makeService()

        let request = ACP.AnyRequest(id: .int(11), method: "session/list", params: nil)
        model.acpService(service, willSend: request)

        let error = ACPError.methodNotFound("Method not found")
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(11), error: error))
        model.acpService(service, didReceiveMessage: response)

        XCTAssertEqual(model.currentSessionListSupport, false)
    }

    func testSessionListItemsUsesPromptAndMtime() {
        let model = makeModel()
        addServer(to: model, agentInfo: makeAgentInfo(loadSession: true))
        let service = makeService()

        let request = ACP.AnyRequest(id: .int(2), method: "session/list", params: nil)
        model.acpService(service, willSend: request)

        let result: ACP.Value = .object([
            "items": .array([
                .object([
                    "sessionId": .string("newer"),
                    "prompt": .string("Do we have readme?"),
                    "cwd": .string("/home/user/Code/Jay"),
                    "mtime": .number(2000),
                ]),
                .object([
                    "sessionId": .string("older"),
                    "prompt": .string(""),
                    "cwd": .string("/home/user/Code"),
                    "mtime": .number(1000),
                ]),
            ]),
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(2), result: result))
        model.acpService(service, didReceiveMessage: response)

        XCTAssertEqual(model.selectedServerViewModel?.sessionSummaries.count, 2)
        XCTAssertEqual(model.selectedServerViewModel?.sessionSummaries[0].id, "newer")
        XCTAssertEqual(model.selectedServerViewModel?.sessionSummaries[0].title, "Do we have readme?")
        XCTAssertNil(model.selectedServerViewModel?.sessionSummaries[1].title)
    }

    func testSessionUpdateAvailableCommandsUpdatesState() {
        let model = makeModel()
        let agentInfo = makeAgentInfo(loadSession: false)
        addServer(to: model, agentInfo: agentInfo)
        let service = makeService()
        let sessionId = "sess-available"
        model.openSession(sessionId)

        if let viewModel = model.selectedServerViewModel?.currentSessionViewModel {
            viewModel.selectedCommandName = "missing"
        }

        let updateMessage = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("available_commands_update"),
            "availableCommands": .array([
                .object([
                    "name": .string("init"),
                    "description": .string("Analyzes the project and creates a file."),
                    "input": .null,
                ]),
            ]),
        ])
        model.acpService(service, didReceiveMessage: updateMessage)

        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.availableCommands.count, 1)
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.availableCommands[0].name, "init")
        XCTAssertNil(model.selectedServerViewModel?.currentSessionViewModel?.selectedCommandName)
    }

    func testSessionUpdateAgentMessageAndToolCallOutput() {
        let model = makeModel()
        let agentInfo = makeAgentInfo(loadSession: false)
        addServer(to: model, agentInfo: agentInfo)
        let service = makeService()
        let sessionId = "sess-stream"
        model.openSession(sessionId)

        let chunk1 = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("Hello")]),
        ])
        let chunk2 = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string(" world")]),
        ])
        model.acpService(service, didReceiveMessage: chunk1)
        model.acpService(service, didReceiveMessage: chunk2)

        let toolCall = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("call_1"),
            "title": .string("Shell: git status"),
            "kind": .string("execute"),
            "status": .string("in_progress"),
        ])
        let toolUpdate = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("call_1"),
            "status": .string("completed"),
            "rawOutput": .string("On branch main"),
        ])
        model.acpService(service, didReceiveMessage: toolCall)
        model.acpService(service, didReceiveMessage: toolUpdate)

        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.count, 1)
        let message = model.selectedServerViewModel?.currentSessionViewModel?.chatMessages[0]
        XCTAssertEqual(message?.segments.first?.text, "Hello world")
        let toolSegment = message?.segments.first(where: { $0.kind == .toolCall })
        XCTAssertEqual(toolSegment?.toolCall?.status, "completed")
        XCTAssertEqual(toolSegment?.toolCall?.output, "On branch main")
        XCTAssertTrue(message?.content.contains("Tool call:") ?? false)
    }

    /// Tests that multiple tool_call messages with the same toolCallId update a single segment
    /// rather than creating duplicates. This matches Claude Code ACP server behavior where:
    /// 1. First tool_call has title: "Terminal" (placeholder)
    /// 2. Second tool_call has title: "`ls`" (actual command)
    /// 3. tool_call_update messages add output and complete status
    func testMultipleToolCallMessagesWithSameIdUpdatesSingleSegment() {
        let model = makeModel()
        let agentInfo = makeAgentInfo(loadSession: false)
        addServer(to: model, agentInfo: agentInfo)
        let service = makeService()
        let sessionId = "sess-tool-dedup"
        model.openSession(sessionId)

        let toolCallId = "toolu_018Vghe97iB5ZYyT8GkoJuoF"

        // First tool_call with placeholder title (as Claude Code sends initially)
        let toolCall1 = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string(toolCallId),
            "title": .string("Terminal"),
            "kind": .string("execute"),
            "status": .string("pending"),
        ])
        model.acpService(service, didReceiveMessage: toolCall1)

        // Second tool_call with actual command title (same toolCallId)
        let toolCall2 = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string(toolCallId),
            "title": .string("`ls`"),
            "kind": .string("execute"),
            "status": .string("pending"),
        ])
        model.acpService(service, didReceiveMessage: toolCall2)

        // tool_call_update with output
        let toolUpdate1 = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string(toolCallId),
        ])
        model.acpService(service, didReceiveMessage: toolUpdate1)

        // tool_call_update with completed status and content
        let toolUpdate2 = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string(toolCallId),
            "status": .string("completed"),
            "rawOutput": .string("ACPClient\nAgents.md\nAgmente"),
        ])
        model.acpService(service, didReceiveMessage: toolUpdate2)

        // Verify only ONE tool call segment exists
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.count, 1)
        let message = model.selectedServerViewModel?.currentSessionViewModel?.chatMessages[0]
        let toolSegments = message?.segments.filter { $0.kind == .toolCall } ?? []
        XCTAssertEqual(toolSegments.count, 1, "Should have exactly one tool call segment, not duplicates")

        // Verify the segment has the updated title (not the placeholder)
        let toolSegment = toolSegments.first
        XCTAssertEqual(toolSegment?.toolCall?.title, "`ls`", "Title should be updated to the actual command")
        XCTAssertEqual(toolSegment?.toolCall?.toolCallId, toolCallId)
        XCTAssertEqual(toolSegment?.toolCall?.kind, "execute")
        XCTAssertEqual(toolSegment?.toolCall?.status, "completed")
        XCTAssertEqual(toolSegment?.toolCall?.output, "ACPClient\nAgents.md\nAgmente")
    }

    func testPromptStopReasonFinishesStreaming() {
        let model = makeModel()
        let agentInfo = makeAgentInfo(loadSession: false)
        addServer(to: model, agentInfo: agentInfo)
        let service = makeService()
        let sessionId = "sess-stop"
        model.openSession(sessionId)

        let chunk = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("Done")]),
        ])
        model.acpService(service, didReceiveMessage: chunk)
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.last?.isStreaming, true)

        let result: ACP.Value = .object(["stopReason": .string("end_turn")])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(6), result: result))
        model.acpService(service, didReceiveMessage: response)

        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.stopReason, "end_turn")
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.last?.isStreaming, false)
    }

    func testSessionUpdateSummaryForMessageChunk() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        let updateMessage = makeSessionUpdateMessage(sessionId: "sess-summary", update: [
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("Hello")]),
        ])
        model.acpService(service, didReceiveMessage: updateMessage)

        XCTAssertEqual(model.updates.last?.message, "session/update [sess-summary] message: Hello")
    }

    func testSessionUpdateSummaryForThoughtChunk() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        let updateMessage = makeSessionUpdateMessage(sessionId: "sess-thought", update: [
            "sessionUpdate": .string("agent_thought_chunk"),
            "content": .object(["type": .string("text"), "text": .string("Thinking...")]),
        ])
        model.acpService(service, didReceiveMessage: updateMessage)

        let summary = model.updates.last?.message ?? ""
        XCTAssertTrue(summary.contains("session/update [sess-thought]"))
        XCTAssertTrue(summary.contains("agent_thought_chunk"))
    }

    func testSessionUpdateThoughtCreatesThoughtSegment() {
        let model = makeModel()
        let agentInfo = makeAgentInfo(loadSession: false)
        addServer(to: model, agentInfo: agentInfo)
        let service = makeService()
        let sessionId = "sess-thinking"
        model.openSession(sessionId)

        let updateMessage = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("agent_thought_chunk"),
            "content": .object(["type": .string("text"), "text": .string("Thinking...")]),
        ])
        model.acpService(service, didReceiveMessage: updateMessage)

        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.count, 1)
        let message = model.selectedServerViewModel?.currentSessionViewModel?.chatMessages[0]
        XCTAssertEqual(message?.segments.count, 1)
        XCTAssertEqual(message?.segments[0].kind, .thought)
        XCTAssertTrue(message?.content.contains("Thinking...") ?? false)
    }

    func testPermissionRequestCreatesToolCallWithOptions() {
        let model = makeModel()
        let agentInfo = makeAgentInfo(loadSession: false)
        addServer(to: model, agentInfo: agentInfo)
        let service = makeService()
        let sessionId = "sess-permission"
        model.openSession(sessionId)

        let params: ACP.Value = .object([
            "sessionId": .string(sessionId),
            "toolCall": .object([
                "toolCallId": .string("run_shell_command-1"),
                "title": .string("git status && git diff"),
                "kind": .string("execute"),
                "status": .string("pending"),
            ]),
            "options": .array([
                .object([
                    "kind": .string("allow_always"),
                    "optionId": .string("proceed_always"),
                    "name": .string("Always Allow git"),
                ]),
                .object([
                    "kind": .string("allow_once"),
                    "optionId": .string("proceed_once"),
                    "name": .string("Allow"),
                ]),
                .object([
                    "kind": .string("reject_once"),
                    "optionId": .string("cancel"),
                    "name": .string("Reject"),
                ]),
            ]),
        ])
        let request = ACP.AnyRequest(id: .int(0), method: "session/request_permission", params: params)
        model.acpService(service, didReceiveMessage: .request(request))

        let toolSegment = model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.first?.segments.first(where: { $0.kind == .toolCall })
        XCTAssertEqual(toolSegment?.toolCall?.status, "awaiting_permission")
        XCTAssertEqual(toolSegment?.toolCall?.acpPermissionRequestId, .int(0))
        XCTAssertEqual(toolSegment?.toolCall?.permissionOptions?.map(\.name), ["Always Allow git", "Allow", "Reject"])
    }

    func testPermissionWorkflowEndToEnd() async throws {
        let model = makeModel()
        let agentInfo = makeAgentInfo(loadSession: false)
        addServer(to: model, agentInfo: agentInfo)
        let sessionId = "sess-permission-flow"
        model.openSession(sessionId)

        let connection = RecordingWebSocketConnection()
        let service = try await makeConnectedService(connection: connection)
        model.setServiceForTesting(service)

        let permissionParams: ACP.Value = .object([
            "sessionId": .string(sessionId),
            "toolCall": .object([
                "toolCallId": .string("run_shell_command-1766"),
                "title": .string("git status && git diff HEAD && git log -n 3"),
                "kind": .string("execute"),
                "status": .string("pending"),
            ]),
            "options": .array([
                .object([
                    "kind": .string("allow_once"),
                    "optionId": .string("proceed_once"),
                    "name": .string("Allow"),
                ]),
            ]),
        ])
        let permissionRequest = ACP.AnyRequest(id: .int(0), method: "session/request_permission", params: permissionParams)
        model.acpService(service, didReceiveMessage: .request(permissionRequest))

        model.sendPermissionResponse(requestId: .int(0), optionId: "proceed_once")
        try await Task.sleep(nanoseconds: 50_000_000)

        let toolSegment = model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.first?.segments.first(where: { $0.kind == .toolCall })
        XCTAssertNil(toolSegment?.toolCall?.permissionOptions)

        guard let lastSent = connection.sentTextsSnapshot().last else {
            XCTFail("Expected permission response to be sent")
            return
        }
        let trimmed = lastSent.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentMessage = try JSONDecoder().decode(ACPWireMessage.self, from: Data(trimmed.utf8))
        guard case let .response(sentResponse) = sentMessage else {
            XCTFail("Expected JSON-RPC response message")
            return
        }
        XCTAssertEqual(sentResponse.id, .int(0))
        let outcome = sentResponse.resultValue?.objectValue?["outcome"]?.objectValue
        XCTAssertEqual(outcome?["outcome"]?.stringValue, "selected")
        XCTAssertEqual(outcome?["optionId"]?.stringValue, "proceed_once")

        let toolUpdate = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("run_shell_command-1766"),
            "status": .string("completed"),
            "content": .array([
                .object([
                    "type": .string("content"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string("On branch main")
                    ])
                ])
            ])
        ])
        let messageChunk = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("Working tree clean")]),
        ])
        model.acpService(service, didReceiveMessage: toolUpdate)
        model.acpService(service, didReceiveMessage: messageChunk)

        let result: ACP.Value = .object(["stopReason": .string("end_turn")])
        let promptResponse = ACPWireMessage.response(ACP.AnyResponse(id: .int(4), result: result))
        model.acpService(service, didReceiveMessage: promptResponse)

        let updatedToolSegment = model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.first?.segments.first(where: { $0.kind == .toolCall })
        XCTAssertEqual(updatedToolSegment?.toolCall?.status, "completed")
        XCTAssertEqual(updatedToolSegment?.toolCall?.output, "On branch main")
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.stopReason, "end_turn")
    }

    // MARK: - End-to-End Workflow Tests

    /// Tests the complete workflow from initialization through session interaction to prompt completion.
    /// Based on actual Gemini CLI agent logs showing:
    /// 1. Initialize with authMethods and promptCapabilities
    /// 2. session/list fails → fall back to local cache
    /// 3. Open cached session, send prompt, receive streaming response
    func testGeminiAgentEndToEndWorkflow() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        // Step 1: Initialize request
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)

        // Step 2: Initialize response (Gemini-style with authMethods and promptCapabilities)
        let initResult: ACP.Value = .object([
            "protocolVersion": .number(1),
            "authMethods": .array([
                .object([
                    "name": .string("Log in with Google"),
                    "description": .null,
                    "id": .string("oauth-personal"),
                ]),
                .object([
                    "description": .string("Requires setting the `GEMINI_API_KEY` environment variable"),
                    "id": .string("gemini-api-key"),
                    "name": .string("Use Gemini API key"),
                ]),
                .object([
                    "id": .string("vertex-ai"),
                    "name": .string("Vertex AI"),
                    "description": .null,
                ]),
            ]),
            "agentCapabilities": .object([
                "promptCapabilities": .object([
                    "audio": .bool(true),
                    "image": .bool(true),
                    "embeddedContext": .bool(true),
                ]),
                "loadSession": .bool(false),
            ]),
        ])
        let initResponse = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: initResult))
        model.acpService(service, didReceiveMessage: initResponse)

        // Verify initialization state
        XCTAssertEqual(model.currentAgentInfo?.capabilities.promptCapabilities.audio, true)
        XCTAssertEqual(model.currentAgentInfo?.capabilities.promptCapabilities.image, true)
        XCTAssertEqual(model.currentAgentInfo?.capabilities.promptCapabilities.embeddedContext, true)
        XCTAssertEqual(model.currentLoadSessionSupport, false)

        // Step 3: session/list request
        let listRequest = ACP.AnyRequest(id: .int(2), method: "session/list", params: nil)
        model.acpService(service, willSend: listRequest)

        // Step 4: session/list fails with "Method not found"
        let listError = ACPError.methodNotFound("Method not found")
        let listErrorResponse = ACPWireMessage.response(ACP.AnyResponse(id: .int(2), error: listError))
        model.acpService(service, didReceiveMessage: listErrorResponse)

        // Verify session list fallback
        XCTAssertEqual(model.currentSessionListSupport, false)

        // Step 5: Open a session (simulating cached session restore)
        let sessionId = "48c8cd45-af43-42e4-a80a-cbbb246d2c82"
        let agentInfo = makeAgentInfo(name: "gemini-cli", loadSession: false)
        addServer(to: model, agentInfo: agentInfo)
        model.openSession(sessionId)

        // Step 6: Send a prompt (tracked by willSend)
        let promptRequest = ACP.AnyRequest(id: .int(4), method: "session/prompt", params: nil)
        model.acpService(service, willSend: promptRequest)

        // Step 7: Receive streaming message chunks
        let chunk1 = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("I'll analyze ")]),
        ])
        let chunk2 = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("the repository ")]),
        ])
        let chunk3 = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("for you.")]),
        ])
        model.acpService(service, didReceiveMessage: chunk1)
        model.acpService(service, didReceiveMessage: chunk2)
        model.acpService(service, didReceiveMessage: chunk3)

        // Verify streaming state
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.count, 1)
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages[0].isStreaming, true)
        XCTAssertTrue(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages[0].content.contains("I'll analyze the repository for you.") == true)

        // Step 8: Prompt response with stopReason
        let promptResult: ACP.Value = .object(["stopReason": .string("end_turn")])
        let promptResponse = ACPWireMessage.response(ACP.AnyResponse(id: .int(4), result: promptResult))
        model.acpService(service, didReceiveMessage: promptResponse)

        // Verify final state
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.stopReason, "end_turn")
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages[0].isStreaming, false)
    }

    func testResumeConnectionRefreshesSessionsWhenInitialized() async throws {
        let model = makeModel()
        addServer(to: model)

        let connection = RecordingWebSocketConnection()
        let service = try await makeConnectedService(connection: connection)
        model.setServiceForTesting(service)

        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)

        let initResult: ACP.Value = .object([
            "protocolVersion": .number(1),
            "agentCapabilities": .object([
                "promptCapabilities": .object([
                    "audio": .bool(false),
                    "image": .bool(false),
                    "embeddedContext": .bool(false),
                ]),
                "listSessions": .bool(true),
            ]),
        ])
        let initResponse = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: initResult))
        model.acpService(service, didReceiveMessage: initResponse)

        model.resumeConnectionIfNeeded()
        let deadline = Date().addingTimeInterval(1.0)
        var sawSessionList = false
        while Date() < deadline {
            let sentMethods = connection.sentTextsSnapshot().compactMap { text -> String? in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let data = trimmed.data(using: .utf8),
                      let message = try? JSONDecoder().decode(ACPWireMessage.self, from: data) else {
                    return nil
                }
                guard case let .request(request) = message else { return nil }
                return request.method
            }
            if sentMethods.contains("session/list") {
                sawSessionList = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(sawSessionList)
    }

    /// Tests end-to-end workflow with tool calls and permission requests.
    /// Simulates a typical agent interaction where:
    /// 1. Agent streams a message
    /// 2. Agent makes a tool call requiring permission
    /// 3. User grants permission
    /// 4. Tool executes and returns output
    /// 5. Agent continues with final response
    func testToolCallWithPermissionEndToEndWorkflow() async throws {
        let model = makeModel()
        let agentInfo = makeAgentInfo(name: "gemini-cli", loadSession: false)
        addServer(to: model, agentInfo: agentInfo)
        let sessionId = "sess-e2e-toolcall"
        model.openSession(sessionId)

        let connection = RecordingWebSocketConnection()
        let service = try await makeConnectedService(connection: connection)
        model.setServiceForTesting(service)

        // Step 1: Agent starts streaming a message
        let introChunk = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("Let me check the repository status. ")]),
        ])
        model.acpService(service, didReceiveMessage: introChunk)
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.count, 1)
        XCTAssertTrue(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages[0].isStreaming == true)

        // Step 2: Agent starts a tool call (pending permission)
        let toolCallStart = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("run_shell_command-42"),
            "title": .string("git status && git diff HEAD"),
            "kind": .string("execute"),
            "status": .string("pending"),
        ])
        model.acpService(service, didReceiveMessage: toolCallStart)

        // Step 3: Permission request arrives
        let permissionParams: ACP.Value = .object([
            "sessionId": .string(sessionId),
            "toolCall": .object([
                "toolCallId": .string("run_shell_command-42"),
                "title": .string("git status && git diff HEAD"),
                "kind": .string("execute"),
                "status": .string("pending"),
            ]),
            "options": .array([
                .object([
                    "kind": .string("allow_always"),
                    "optionId": .string("proceed_always"),
                    "name": .string("Always Allow git"),
                ]),
                .object([
                    "kind": .string("allow_once"),
                    "optionId": .string("proceed_once"),
                    "name": .string("Allow"),
                ]),
                .object([
                    "kind": .string("reject_once"),
                    "optionId": .string("cancel"),
                    "name": .string("Reject"),
                ]),
            ]),
        ])
        let permissionRequest = ACP.AnyRequest(id: .int(0), method: "session/request_permission", params: permissionParams)
        model.acpService(service, didReceiveMessage: .request(permissionRequest))

        // Verify permission state
        let pendingToolSegment = model.selectedServerViewModel?.currentSessionViewModel?.chatMessages[0].segments.first(where: { $0.kind == .toolCall })
        XCTAssertEqual(pendingToolSegment?.toolCall?.status, "awaiting_permission")
        XCTAssertEqual(pendingToolSegment?.toolCall?.permissionOptions?.count, 3)

        // Step 4: User grants permission (Allow)
        model.sendPermissionResponse(requestId: .int(0), optionId: "proceed_once")
        try await Task.sleep(nanoseconds: 50_000_000)

        // Verify permission response was sent
        guard let lastSent = connection.sentTextsSnapshot().last else {
            XCTFail("Expected permission response to be sent")
            return
        }
        let trimmed = lastSent.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentMessage = try JSONDecoder().decode(ACPWireMessage.self, from: Data(trimmed.utf8))
        guard case let .response(sentResponse) = sentMessage else {
            XCTFail("Expected JSON-RPC response message")
            return
        }
        XCTAssertEqual(sentResponse.id, .int(0))

        // Step 5: Tool call executes and updates
        let toolInProgress = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("run_shell_command-42"),
            "status": .string("in_progress"),
        ])
        model.acpService(service, didReceiveMessage: toolInProgress)

        let toolCompleted = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("run_shell_command-42"),
            "status": .string("completed"),
            "rawOutput": .string("On branch main\nYour branch is up to date with 'origin/main'.\n\nnothing to commit, working tree clean"),
        ])
        model.acpService(service, didReceiveMessage: toolCompleted)

        // Verify tool call completed
        let completedToolSegment = model.selectedServerViewModel?.currentSessionViewModel?.chatMessages[0].segments.first(where: { $0.kind == .toolCall })
        XCTAssertEqual(completedToolSegment?.toolCall?.status, "completed")
        XCTAssertTrue(completedToolSegment?.toolCall?.output?.contains("working tree clean") ?? false)

        // Step 6: Agent continues with final response
        let followUpChunk = makeSessionUpdateMessage(sessionId: sessionId, update: [
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("The repository is clean with no uncommitted changes.")]),
        ])
        model.acpService(service, didReceiveMessage: followUpChunk)

        // Step 7: Prompt completes
        let promptResult: ACP.Value = .object(["stopReason": .string("end_turn")])
        let promptResponse = ACPWireMessage.response(ACP.AnyResponse(id: .int(5), result: promptResult))
        model.acpService(service, didReceiveMessage: promptResponse)

        // Verify final state
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.stopReason, "end_turn")
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages[0].isStreaming, false)
        XCTAssertTrue(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages[0].content.contains("Let me check the repository status") == true)
        XCTAssertTrue(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages[0].content.contains("clean with no uncommitted changes") == true)
    }

    // MARK: - Session Preview Tests (Regression tests for PR review feedback)

    func testGetLastMessagePreview_AssistantMessage_TruncatesTo60Chars() {
        let model = makeModel()
        addServer(to: model)
        guard let serverId = model.selectedServerId else {
            XCTFail("No server selected")
            return
        }
        let sessionId = "test-session"

        // Create a long assistant message (> 60 chars)
        let longContent = String(repeating: "a", count: 80)
        let message = ChatMessage(role: .assistant, content: longContent, isStreaming: false)
        model.saveMessages([message], for: serverId, sessionId: sessionId)

        let preview = model.getLastMessagePreview(for: serverId, sessionId: sessionId)

        XCTAssertNotNil(preview)
        XCTAssertEqual(preview?.count, 61) // 60 chars + "…"
        XCTAssertTrue(preview?.hasSuffix("…") ?? false, "Long assistant messages should be truncated with ellipsis")
    }

    func testGetLastMessagePreview_UserMessage_HasYouPrefixAndTruncatesTo50Chars() {
        let model = makeModel()
        addServer(to: model)
        guard let serverId = model.selectedServerId else {
            XCTFail("No server selected")
            return
        }
        let sessionId = "test-session"

        // Create a long user message (> 50 chars)
        let longContent = String(repeating: "b", count: 70)
        let message = ChatMessage(role: .user, content: longContent, isStreaming: false)
        model.saveMessages([message], for: serverId, sessionId: sessionId)

        let preview = model.getLastMessagePreview(for: serverId, sessionId: sessionId)

        XCTAssertNotNil(preview)
        XCTAssertTrue(preview?.hasPrefix("You: ") ?? false, "User messages should have 'You: ' prefix")
        XCTAssertEqual(preview?.count, 56) // "You: " (5) + 50 chars + "…" (1)
        XCTAssertTrue(preview?.hasSuffix("…") ?? false, "Long user messages should be truncated with ellipsis")
    }

    func testGetLastMessagePreview_SystemMessage_ReturnsNil() {
        let model = makeModel()
        addServer(to: model)
        guard let serverId = model.selectedServerId else {
            XCTFail("No server selected")
            return
        }
        let sessionId = "test-session"

        // Create a system message (error messages, etc.)
        let message = ChatMessage(role: .system, content: "Error: Something went wrong", isStreaming: false)
        model.saveMessages([message], for: serverId, sessionId: sessionId)

        let preview = model.getLastMessagePreview(for: serverId, sessionId: sessionId)

        XCTAssertNil(preview, "System messages should be ignored in preview (may contain verbose error text)")
    }

    func testGetLastMessagePreview_EmptyContent_ReturnsNil() {
        let model = makeModel()
        addServer(to: model)
        guard let serverId = model.selectedServerId else {
            XCTFail("No server selected")
            return
        }
        let sessionId = "test-session"

        // Create messages with empty content
        let emptyAssistant = ChatMessage(role: .assistant, content: "   ", isStreaming: false)
        model.saveMessages([emptyAssistant], for: serverId, sessionId: sessionId)

        let preview = model.getLastMessagePreview(for: serverId, sessionId: sessionId)

        XCTAssertNil(preview, "Empty content should return nil, not '...'")
    }

    func testGetLastMessagePreview_ShortMessages_NotTruncated() {
        let model = makeModel()
        addServer(to: model)
        guard let serverId = model.selectedServerId else {
            XCTFail("No server selected")
            return
        }
        let sessionId = "test-session"

        // Short assistant message
        let shortAssistant = ChatMessage(role: .assistant, content: "Hello", isStreaming: false)
        model.saveMessages([shortAssistant], for: serverId, sessionId: sessionId)

        let assistantPreview = model.getLastMessagePreview(for: serverId, sessionId: sessionId)
        XCTAssertEqual(assistantPreview, "Hello", "Short assistant messages should not be truncated")

        // Short user message
        let shortUser = ChatMessage(role: .user, content: "Hi", isStreaming: false)
        model.saveMessages([shortUser], for: serverId, sessionId: sessionId)

        let userPreview = model.getLastMessagePreview(for: serverId, sessionId: sessionId)
        XCTAssertEqual(userPreview, "You: Hi", "Short user messages should have prefix but not be truncated")
    }

    // MARK: - Mode Change Logging Tests (Regression test for PR review feedback)

    func testModeChanged_LogsMessage() {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        // Initialize first
        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)

        let initResult: ACP.Value = .object([
            "protocolVersion": .number(1),
            "agentInfo": .object([
                "name": .string("test-agent"),
                "version": .string("1.0.0"),
            ]),
            "agentCapabilities": .object([:]),
        ])
        let initResponse = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: initResult))
        model.acpService(service, didReceiveMessage: initResponse)

        // Clear updates to isolate mode change log
        let updateCountBefore = model.updates.count

        // Send a session/set_mode response that triggers mode change
        let setModeRequest = ACP.AnyRequest(id: .int(2), method: "session/set_mode", params: nil)
        model.acpService(service, willSend: setModeRequest)

        let modeResult: ACP.Value = .object([
            "currentModeId": .string("code")
        ])
        let modeResponse = ACPWireMessage.response(ACP.AnyResponse(id: .int(2), result: modeResult))
        model.acpService(service, didReceiveMessage: modeResponse)

        // Check that "Mode changed to: code" was logged
        let newUpdates = model.updates.dropFirst(updateCountBefore)
        let modeChangeLog = newUpdates.first { $0.message.contains("Mode changed to: code") }

        XCTAssertNotNil(modeChangeLog, "Mode change should be logged even for response actions (not just notifications)")
    }
}