import XCTest
import ACP
@testable import ACPClient

final class AgentInfoParsingTests: XCTestCase {
    func testParseAgentInfoFromJSONValue() {
        let result: [String: ACP.Value] = [
            "agentInfo": .object([
                "name": .string("qwen-code"),
                "version": .string("0.4.0"),
                "title": .string("Qwen Code"),
            ]),
            "agentCapabilities": .object([
                "loadSession": .bool(true),
                "listSessions": .bool(false),
                "sessionCapabilities": .object([
                    "resume": .object([:]),
                ]),
                "promptCapabilities": .object([
                    "image": .bool(true),
                    "audio": .bool(true),
                    "embeddedContext": .bool(true),
                ]),
            ]),
            "modes": .object([
                "availableModes": .array([
                    .object([
                        "id": .string("default"),
                        "name": .string("Default"),
                        "description": .string("Require approval"),
                    ]),
                ]),
            ]),
        ]

        let info = AgentProfile.parse(from: result)

        XCTAssertEqual(info.name, "qwen-code")
        XCTAssertEqual(info.displayNameWithVersion, "Qwen Code v0.4.0")
        XCTAssertEqual(info.capabilities.loadSession, true)
        XCTAssertEqual(info.capabilities.resumeSession, true)
        XCTAssertEqual(info.capabilities.listSessions, false)
        XCTAssertEqual(info.capabilities.sessionListRequiresCwd, true)
        XCTAssertEqual(info.capabilities.promptCapabilities.image, true)
        XCTAssertEqual(info.capabilities.promptCapabilities.audio, true)
        XCTAssertEqual(info.capabilities.promptCapabilities.embeddedContext, true)
        XCTAssertEqual(info.modes.count, 1)
        XCTAssertEqual(info.modes.first?.id, "default")
    }

    func testParseAvailableCommands() {
        let update: [String: ACP.Value] = [
            "availableCommands": .array([
                .object([
                    "name": .string("init"),
                    "description": .string("Analyze the project."),
                    "input": .object([
                        "hint": .string("Optional extra context"),
                    ]),
                ]),
            ]),
        ]

        let commands = SessionCommand.parse(from: update)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.name, "init")
        XCTAssertEqual(commands.first?.description, "Analyze the project.")
        XCTAssertEqual(commands.first?.inputHint, "Optional extra context")
    }
}