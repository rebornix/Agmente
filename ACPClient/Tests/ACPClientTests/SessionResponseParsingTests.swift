import XCTest
import ACP
@testable import ACPClient

final class SessionResponseParsingTests: XCTestCase {
    
    // MARK: - parseSessionNew Tests
    
    func testParseSessionNewBasic() {
        let result: ACP.Value = .object([
            "sessionId": .string("session-123")
        ])
        
        let parsed = ACPSessionResponseParser.parseSessionNew(result: result)
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.sessionId, "session-123")
        XCTAssertNil(parsed?.cwd)
        XCTAssertNil(parsed?.modes)
    }
    
    func testParseSessionNewWithCwd() {
        let result: ACP.Value = .object([
            "sessionId": .string("session-123"),
            "cwd": .string("/path/to/project")
        ])
        
        let parsed = ACPSessionResponseParser.parseSessionNew(result: result)
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.sessionId, "session-123")
        XCTAssertEqual(parsed?.cwd, "/path/to/project")
    }
    
    func testParseSessionNewWithWorkingDirectory() {
        let result: ACP.Value = .object([
            "session": .string("session-456"),
            "workingDirectory": .string("/home/user/project")
        ])
        
        let parsed = ACPSessionResponseParser.parseSessionNew(result: result)
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.sessionId, "session-456")
        XCTAssertEqual(parsed?.cwd, "/home/user/project")
    }
    
    func testParseSessionNewWithIdAlternative() {
        let result: ACP.Value = .object([
            "id": .string("session-789")
        ])
        
        let parsed = ACPSessionResponseParser.parseSessionNew(result: result)
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.sessionId, "session-789")
    }
    
    func testParseSessionNewWithModes() {
        let result: ACP.Value = .object([
            "sessionId": .string("session-123"),
            "modes": .object([
                "availableModes": .array([
                    .object([
                        "id": .string("mode-1"),
                        "name": .string("Mode One"),
                        "description": .string("First mode")
                    ]),
                    .object([
                        "id": .string("mode-2"),
                        "name": .string("Mode Two")
                    ])
                ]),
                "currentModeId": .string("mode-1")
            ])
        ])
        
        let parsed = ACPSessionResponseParser.parseSessionNew(result: result)
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.sessionId, "session-123")
        XCTAssertNotNil(parsed?.modes)
        XCTAssertEqual(parsed?.modes?.availableModes.count, 2)
        XCTAssertEqual(parsed?.modes?.availableModes[0].id, "mode-1")
        XCTAssertEqual(parsed?.modes?.availableModes[0].name, "Mode One")
        XCTAssertEqual(parsed?.modes?.availableModes[0].description, "First mode")
        XCTAssertEqual(parsed?.modes?.availableModes[1].id, "mode-2")
        XCTAssertEqual(parsed?.modes?.availableModes[1].name, "Mode Two")
        XCTAssertNil(parsed?.modes?.availableModes[1].description)
        XCTAssertEqual(parsed?.modes?.currentModeId, "mode-1")
    }
    
    func testParseSessionNewWithFallbacks() {
        let result: ACP.Value = .object([:])
        
        let parsed = ACPSessionResponseParser.parseSessionNew(
            result: result,
            fallbackSessionId: "fallback-id",
            fallbackCwd: "/fallback/path"
        )
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.sessionId, "fallback-id")
        XCTAssertEqual(parsed?.cwd, "/fallback/path")
    }
    
    func testParseSessionNewNilResult() {
        let parsed = ACPSessionResponseParser.parseSessionNew(result: nil)
        
        XCTAssertNil(parsed)
    }
    
    func testParseSessionNewNilResultWithFallback() {
        let parsed = ACPSessionResponseParser.parseSessionNew(
            result: nil,
            fallbackSessionId: "fallback-id"
        )
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.sessionId, "fallback-id")
    }
    
    // MARK: - parseSessionLoad Tests
    
    func testParseSessionLoadBasic() {
        let result: ACP.Value = .object([
            "sessionId": .string("session-456"),
            "cwd": .string("/path/to")
        ])
        
        let parsed = ACPSessionResponseParser.parseSessionLoad(
            result: result,
            requestedSessionId: "session-456"
        )
        
        XCTAssertEqual(parsed.sessionId, "session-456")
        XCTAssertEqual(parsed.cwd, "/path/to")
        XCTAssertNil(parsed.modes)
        XCTAssertTrue(parsed.history?.isEmpty ?? true)
    }
    
    func testParseSessionLoadWithHistory() {
        let result: ACP.Value = .object([
            "sessionId": .string("session-456"),
            "history": .array([
                .object([
                    "role": .string("user"),
                    "content": .string("Hello")
                ]),
                .object([
                    "role": .string("assistant"),
                    "content": .string("Hi there!")
                ])
            ])
        ])
        
        let parsed = ACPSessionResponseParser.parseSessionLoad(
            result: result,
            requestedSessionId: "session-456"
        )
        
        XCTAssertEqual(parsed.sessionId, "session-456")
        XCTAssertEqual(parsed.history?.count, 2)
        XCTAssertEqual(parsed.history?[0].role, .user)
        XCTAssertEqual(parsed.history?[0].content, "Hello")
        XCTAssertEqual(parsed.history?[1].role, .assistant)
        XCTAssertEqual(parsed.history?[1].content, "Hi there!")
    }
    
    func testParseSessionLoadWithMessagesArray() {
        let result: ACP.Value = .object([
            "sessionId": .string("session-456"),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .string("Question")
                ])
            ])
        ])
        
        let parsed = ACPSessionResponseParser.parseSessionLoad(
            result: result,
            requestedSessionId: "session-456"
        )
        
        XCTAssertEqual(parsed.history?.count, 1)
        XCTAssertEqual(parsed.history?[0].role, .user)
        XCTAssertEqual(parsed.history?[0].content, "Question")
    }
    
    func testParseSessionLoadWithTimestamp() {
        let result: ACP.Value = .object([
            "sessionId": .string("session-456"),
            "history": .array([
                .object([
                    "role": .string("user"),
                    "content": .string("Hello"),
                    "timestamp": .string("2024-01-15T10:30:00Z")
                ])
            ])
        ])
        
        let parsed = ACPSessionResponseParser.parseSessionLoad(
            result: result,
            requestedSessionId: "session-456"
        )
        
        XCTAssertEqual(parsed.history?.count, 1)
        XCTAssertNotNil(parsed.history?[0].timestamp)
    }
    
    func testParseSessionLoadWithModes() {
        let result: ACP.Value = .object([
            "sessionId": .string("session-456"),
            "modes": .object([
                "availableModes": .array([
                    .object([
                        "id": .string("code"),
                        "name": .string("Code Mode")
                    ])
                ]),
                "currentModeId": .string("code")
            ])
        ])
        
        let parsed = ACPSessionResponseParser.parseSessionLoad(
            result: result,
            requestedSessionId: "session-456"
        )
        
        XCTAssertNotNil(parsed.modes)
        XCTAssertEqual(parsed.modes?.availableModes.count, 1)
        XCTAssertEqual(parsed.modes?.currentModeId, "code")
    }
    
    func testParseSessionLoadNilResult() {
        let parsed = ACPSessionResponseParser.parseSessionLoad(
            result: nil,
            requestedSessionId: "fallback-id"
        )
        
        XCTAssertEqual(parsed.sessionId, "fallback-id")
        XCTAssertNil(parsed.cwd)
        XCTAssertTrue(parsed.history?.isEmpty ?? true)
    }
    
    // MARK: - parseSetMode Tests
    
    func testParseSetModeWithCurrentModeId() {
        let result: ACP.Value = .object([
            "currentModeId": .string("advanced")
        ])
        
        let parsed = ACPSessionResponseParser.parseSetMode(result: result)
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.currentModeId, "advanced")
    }
    
    func testParseSetModeWithModeId() {
        let result: ACP.Value = .object([
            "modeId": .string("basic")
        ])
        
        let parsed = ACPSessionResponseParser.parseSetMode(result: result)
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.currentModeId, "basic")
    }
    
    func testParseSetModeNilResult() {
        let parsed = ACPSessionResponseParser.parseSetMode(result: nil)
        
        XCTAssertNil(parsed)
    }
    
    func testParseSetModeNoModeId() {
        let result: ACP.Value = .object([
            "success": .bool(true)
        ])
        
        let parsed = ACPSessionResponseParser.parseSetMode(result: result)
        
        XCTAssertNil(parsed)
    }
    
    // MARK: - parseModes Tests
    
    func testParseModesComplete() {
        let resultDict: [String: ACP.Value] = [
            "modes": .object([
                "availableModes": .array([
                    .object([
                        "id": .string("standard"),
                        "name": .string("Standard"),
                        "description": .string("Default mode")
                    ]),
                    .object([
                        "id": .string("expert"),
                        "name": .string("Expert"),
                        "description": .string("Advanced mode")
                    ])
                ]),
                "currentModeId": .string("standard")
            ])
        ]
        
        let parsed = ACPSessionResponseParser.parseModes(from: resultDict)
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.availableModes.count, 2)
        XCTAssertEqual(parsed?.availableModes[0].id, "standard")
        XCTAssertEqual(parsed?.availableModes[1].id, "expert")
        XCTAssertEqual(parsed?.currentModeId, "standard")
    }
    
    func testParseModesOnlyCurrentModeId() {
        let resultDict: [String: ACP.Value] = [
            "modes": .object([
                "currentModeId": .string("active-mode")
            ])
        ]
        
        let parsed = ACPSessionResponseParser.parseModes(from: resultDict)
        
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed?.availableModes.isEmpty ?? false)
        XCTAssertEqual(parsed?.currentModeId, "active-mode")
    }
    
    func testParseModesOnlyAvailableModes() {
        let resultDict: [String: ACP.Value] = [
            "modes": .object([
                "availableModes": .array([
                    .object([
                        "id": .string("only-mode"),
                        "name": .string("Only Mode")
                    ])
                ])
            ])
        ]
        
        let parsed = ACPSessionResponseParser.parseModes(from: resultDict)
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.availableModes.count, 1)
        XCTAssertNil(parsed?.currentModeId)
    }
    
    func testParseModesEmptyModes() {
        let resultDict: [String: ACP.Value] = [
            "modes": .object([:])
        ]
        
        let parsed = ACPSessionResponseParser.parseModes(from: resultDict)
        
        XCTAssertNil(parsed)
    }
    
    func testParseModesNoModes() {
        let resultDict: [String: ACP.Value] = [
            "sessionId": .string("session-123")
        ]
        
        let parsed = ACPSessionResponseParser.parseModes(from: resultDict)
        
        XCTAssertNil(parsed)
    }
    
    func testParseModesNilDict() {
        let parsed = ACPSessionResponseParser.parseModes(from: nil)
        
        XCTAssertNil(parsed)
    }
    
    func testParseModesSkipsInvalidModes() {
        let resultDict: [String: ACP.Value] = [
            "modes": .object([
                "availableModes": .array([
                    .object([
                        "id": .string("valid"),
                        "name": .string("Valid Mode")
                    ]),
                    .object([
                        // Missing required fields
                        "description": .string("Invalid mode")
                    ]),
                    .object([
                        "id": .string("also-valid"),
                        "name": .string("Also Valid")
                    ])
                ])
            ])
        ]
        
        let parsed = ACPSessionResponseParser.parseModes(from: resultDict)
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.availableModes.count, 2)
        XCTAssertEqual(parsed?.availableModes[0].id, "valid")
        XCTAssertEqual(parsed?.availableModes[1].id, "also-valid")
    }
    
    // MARK: - ACPSessionNewResult Tests
    
    func testSessionNewResultEquality() {
        let result1 = ACPSessionNewResult(
            sessionId: "session-1",
            cwd: "/path",
            modes: ACPModesInfo(availableModes: [], currentModeId: "mode-1")
        )
        let result2 = ACPSessionNewResult(
            sessionId: "session-1",
            cwd: "/path",
            modes: ACPModesInfo(availableModes: [], currentModeId: "mode-1")
        )
        
        XCTAssertEqual(result1, result2)
    }
    
    // MARK: - ACPModesInfo Tests
    
    func testModesInfoEquality() {
        let modes1 = ACPModesInfo(
            availableModes: [AgentModeOption(id: "m1", name: "Mode 1")],
            currentModeId: "m1"
        )
        let modes2 = ACPModesInfo(
            availableModes: [AgentModeOption(id: "m1", name: "Mode 1")],
            currentModeId: "m1"
        )
        
        XCTAssertEqual(modes1, modes2)
    }
    
    // MARK: - ACPHistoryMessage Tests
    
    func testHistoryMessageEquality() {
        let date = Date()
        let msg1 = ACPHistoryMessage(role: .user, content: "Hello", timestamp: date)
        let msg2 = ACPHistoryMessage(role: .user, content: "Hello", timestamp: date)
        
        XCTAssertEqual(msg1, msg2)
    }
}