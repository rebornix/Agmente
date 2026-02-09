import XCTest
import ACP
@testable import ACPClient

final class InitializeParsingTests: XCTestCase {
    func testParseInitializeACPExtractsModesAndAuthMethods() {
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
                ]),
            ]),
            "authMethods": .array([
                .object([
                    "id": .string("oauth-personal"),
                    "name": .string("Log in with Google"),
                    "description": .null,
                ]),
                .object([
                    "id": .string("gemini-api-key"),
                    "name": .string("Use Gemini API key"),
                    "description": .string("Requires setting the GEMINI_API_KEY environment variable"),
                ]),
            ]),
        ])

        let parsed = ACPInitializeParser.parse(result: result)

        XCTAssertEqual(parsed?.connectedProtocol, .acp)
        XCTAssertEqual(parsed?.agentInfo?.name, "qwen-code")
        XCTAssertEqual(parsed?.agentInfo?.modes.count, 2)
        XCTAssertEqual(parsed?.currentModeId, "default")
        XCTAssertEqual(parsed?.authMethods.count, 2)
        XCTAssertTrue(parsed?.promptCapabilitiesDeclared ?? false)
    }

    func testParseInitializeCodexUsesUserAgent() {
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
        ])

        let parsed = ACPInitializeParser.parse(result: result)

        XCTAssertEqual(parsed?.connectedProtocol, .codexAppServer)
        XCTAssertEqual(parsed?.agentInfo?.name, "codex-app-server")
        XCTAssertEqual(parsed?.agentInfo?.description, "codex/1.0.0")
        XCTAssertEqual(parsed?.authMethods.count, 0)
        XCTAssertFalse(parsed?.promptCapabilitiesDeclared ?? true)
    }

    func testParseInitializePrefersACPWhenMarkersExist() {
        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0"),
            "protocolVersion": .number(1),
            "agentInfo": .object([
                "name": .string("test-agent"),
            ]),
        ])

        let parsed = ACPInitializeParser.parse(result: result)

        XCTAssertEqual(parsed?.connectedProtocol, .acp)
        XCTAssertEqual(parsed?.agentInfo?.name, "test-agent")
    }
}