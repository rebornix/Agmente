import XCTest
import ACP
@testable import ACPClient

final class PermissionRequestParsingTests: XCTestCase {
    func testParsePermissionRequestUsesToolCallAndOptions() {
        let params: ACP.Value = .object([
            "sessionId": .string("sess-1"),
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
            ]),
        ])

        let parsed = ACPPermissionRequestParser.parse(params: params)

        XCTAssertEqual(parsed?.sessionId, "sess-1")
        XCTAssertEqual(parsed?.toolCallId, "run_shell_command-1")
        XCTAssertEqual(parsed?.toolCallTitle, "git status && git diff")
        XCTAssertEqual(parsed?.toolCallKind, "execute")
        XCTAssertEqual(parsed?.options.count, 2)
        XCTAssertEqual(parsed?.options.first?.kind, .allowAlways)
    }

    func testParsePermissionRequestDefaultsTitleAndEmptyOptions() {
        let params: ACP.Value = .object([
            "sessionId": .string("sess-2"),
            "toolCall": .object([
                "toolCallId": .string("tool-2"),
            ]),
        ])

        let parsed = ACPPermissionRequestParser.parse(params: params)

        XCTAssertEqual(parsed?.toolCallTitle, "Unknown operation")
        XCTAssertEqual(parsed?.options.count, 0)
    }
}