import XCTest
import ACP
@testable import ACPClient

final class SessionUpdateParsingTests: XCTestCase {
    func testSummarizeAgentMessageChunk() {
        let params: ACP.Value = .object([
            "sessionId": .string("sess-1"),
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("Hello"),
                ]),
            ]),
        ])

        let summary = ACPSessionUpdateParser.summarize(params: params)

        XCTAssertEqual(summary, "session/update [sess-1] message: Hello")
    }

    func testSummarizeToolCall() {
        let params: ACP.Value = .object([
            "sessionId": .string("sess-1"),
            "update": .object([
                "sessionUpdate": .string("tool_call"),
                "title": .string("Shell: git status"),
                "kind": .string("execute"),
            ]),
        ])

        let summary = ACPSessionUpdateParser.summarize(params: params)

        XCTAssertEqual(summary, "session/update [sess-1] tool_call [execute] Shell: git status")
    }

    func testSummarizeToolCallUpdate() {
        let params: ACP.Value = .object([
            "sessionId": .string("sess-1"),
            "update": .object([
                "sessionUpdate": .string("tool_call_update"),
                "status": .string("completed"),
            ]),
        ])

        let summary = ACPSessionUpdateParser.summarize(params: params)

        XCTAssertEqual(summary, "session/update [sess-1] tool_call_update: completed")
    }

    func testSummarizeCurrentModeUpdate() {
        let params: ACP.Value = .object([
            "sessionId": .string("sess-1"),
            "update": .object([
                "sessionUpdate": .string("current_mode_update"),
                "modeId": .string("plan"),
            ]),
        ])

        let summary = ACPSessionUpdateParser.summarize(params: params)

        XCTAssertEqual(summary, "session/update [sess-1] mode -> plan")
    }

    func testSummarizeAvailableCommandsUpdate() {
        let params: ACP.Value = .object([
            "sessionId": .string("sess-1"),
            "update": .object([
                "sessionUpdate": .string("available_commands_update"),
            ]),
        ])

        let summary = ACPSessionUpdateParser.summarize(params: params)

        XCTAssertEqual(summary, "session/update [sess-1] available commands updated")
    }

    func testExtractTextFromArrayPayload() {
        let update: [String: ACP.Value] = [
            "content": .array([
                .object([
                    "content": .object([
                        "text": .string("chunk"),
                    ]),
                ]),
            ]),
        ]

        let text = ACPSessionUpdateParser.extractText(from: update)

        XCTAssertEqual(text, "chunk")
    }

    func testParseParamsReturnsSessionAndKind() {
        let params: ACP.Value = .object([
            "sessionId": .string("sess-2"),
            "update": .object([
                "sessionUpdate": .string("tool_call"),
            ]),
        ])

        let parsed = ACPSessionUpdateParser.parse(params: params)

        XCTAssertEqual(parsed.sessionId, "sess-2")
        XCTAssertEqual(parsed.kind, "tool_call")
        XCTAssertEqual(parsed.update["sessionUpdate"]?.stringValue, "tool_call")
    }

    func testToolCallHelpersPreferTitleAndRawOutput() {
        let update: [String: ACP.Value] = [
            "title": .string("Shell: ls"),
            "kind": .string("execute"),
            "status": .string("completed"),
            "toolCallId": .string("call-1"),
            "rawOutput": .string("OK"),
            "content": .object(["text": .string("ignored")]),
        ]

        XCTAssertEqual(ACPSessionUpdateParser.toolCallTitle(from: update), "Shell: ls")
        XCTAssertEqual(ACPSessionUpdateParser.toolCallKind(from: update), "execute")
        XCTAssertEqual(ACPSessionUpdateParser.toolCallStatus(from: update), "completed")
        XCTAssertEqual(ACPSessionUpdateParser.toolCallId(from: update), "call-1")
        XCTAssertEqual(ACPSessionUpdateParser.toolCallOutput(from: update), "OK")
    }

    func testToolCallOutputUsesContentArray() {
        let update: [String: ACP.Value] = [
            "status": .string("completed"),
            "toolCallId": .string("call-2"),
            "content": .array([
                .object([
                    "type": .string("content"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string("On branch main"),
                    ]),
                ]),
            ]),
        ]

        XCTAssertEqual(ACPSessionUpdateParser.toolCallOutput(from: update), "On branch main")
    }

    func testUserMessageTextUsesContentText() {
        let update: [String: ACP.Value] = [
            "content": .object([
                "type": .string("text"),
                "text": .string("Hi"),
            ]),
        ]

        XCTAssertEqual(ACPSessionUpdateParser.userMessageText(from: update), "Hi")
    }
}