import XCTest
import ACP
@testable import ACPClient

final class ResponseDispatcherTests: XCTestCase {
    
    // MARK: - Session Activation Tests
    
    func testSessionNewDispatch() {
        let result: ACP.Value = .object([
            "sessionId": .string("session-123"),
            "cwd": .string("/path/to/project")
        ])
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/new",
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .sessionActivated(let activation) = action {
                return activation.sessionId == "session-123" && activation.cwd == "/path/to/project"
            }
            return false
        })
        XCTAssertTrue(actions.contains { action in
            if case .sessionMaterialized(let id) = action {
                return id == "session-123"
            }
            return false
        })
    }
    
    func testSessionCreateDispatch() {
        let result: ACP.Value = .object([
            "sessionId": .string("session-456")
        ])
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/create",
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .sessionActivated(let activation) = action {
                return activation.sessionId == "session-456"
            }
            return false
        })
        XCTAssertTrue(actions.contains { action in
            if case .sessionMaterialized(let id) = action {
                return id == "session-456"
            }
            return false
        })
    }
    
    func testSessionLoadDispatch() {
        let result: ACP.Value = .object([
            "sessionId": .string("loaded-session"),
            "cwd": .string("/loaded/path")
        ])
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/load",
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .sessionActivated(let activation) = action {
                return activation.sessionId == "loaded-session"
            }
            return false
        })
        XCTAssertTrue(actions.contains { action in
            if case .sessionMaterialized(let id) = action {
                return id == "loaded-session"
            }
            return false
        })
        XCTAssertTrue(actions.contains { action in
            if case .sessionLoadCompleted = action {
                return true
            }
            return false
        })
    }
    
    func testSessionResumeDispatch() {
        let result: ACP.Value = .object([
            "sessionId": .string("resumed-session")
        ])
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/resume",
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .sessionActivated(let activation) = action {
                return activation.sessionId == "resumed-session"
            }
            return false
        })
        XCTAssertTrue(actions.contains { action in
            if case .sessionMaterialized(let id) = action {
                return id == "resumed-session"
            }
            return false
        })
    }
    
    // MARK: - Session Migration Tests
    
    func testSessionMigrationOnPlaceholderChange() {
        let result: ACP.Value = .object([
            "sessionId": .string("real-session-id")
        ])
        
        let context = ACPResponseDispatchContext(
            pendingPlaceholderId: "placeholder-id",
            pendingCwd: nil
        )
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/new",
            context: context
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .sessionMigrated(let from, let to) = action {
                return from == "placeholder-id" && to == "real-session-id"
            }
            return false
        })
    }
    
    func testNoMigrationWhenIdMatches() {
        let result: ACP.Value = .object([
            "sessionId": .string("same-id")
        ])
        
        let context = ACPResponseDispatchContext(
            pendingPlaceholderId: "same-id",
            pendingCwd: nil
        )
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/new",
            context: context
        )
        
        XCTAssertFalse(actions.contains { action in
            if case .sessionMigrated = action {
                return true
            }
            return false
        })
    }
    
    // MARK: - Mode Change Tests
    
    func testSetModeDispatch() {
        let result: ACP.Value = .object([
            "currentModeId": .string("code-mode")
        ])
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/set_mode",
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .modeChanged(let modeId) = action {
                return modeId == "code-mode"
            }
            return false
        })
    }
    
    func testSetModeWithAlternateModeIdKey() {
        let result: ACP.Value = .object([
            "modeId": .string("plan-mode")
        ])
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/set_mode",
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .modeChanged(let modeId) = action {
                return modeId == "plan-mode"
            }
            return false
        })
    }
    
    // MARK: - Initialize Tests
    
    func testInitializeDispatch() {
        let result: ACP.Value = .object([
            "agentInfo": .object([
                "name": .string("TestAgent"),
                "version": .string("1.0.0")
            ])
        ])
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "initialize",
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .initialized = action {
                return true
            }
            return false
        })
    }
    
    func testInitializeFallbackDetection() {
        // Some servers return agentInfo even without method tracking
        let result: ACP.Value = .object([
            "agent": .object([
                "name": .string("Agent")
            ])
        ])
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: nil,  // Method not tracked
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .initialized = action {
                return true
            }
            return false
        })
    }
    
    // MARK: - Stop Reason Tests
    
    func testStopReasonDispatch() {
        let result: ACP.Value = .object([
            "stopReason": .string("end_turn")
        ])
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/prompt",
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .stopReason(let reason) = action {
                return reason == "end_turn"
            }
            return false
        })
    }
    
    // MARK: - Session List Tests
    
    func testSessionListDispatch() {
        let result: ACP.Value = .object([
            "sessions": .array([
                .object([
                    "sessionId": .string("session-1"),
                    "title": .string("First Session")
                ]),
                .object([
                    "sessionId": .string("session-2"),
                    "title": .string("Second Session")
                ])
            ])
        ])
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/list",
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .sessionListReceived(let listResult) = action {
                return listResult.sessions.count == 2
            }
            return false
        })
        XCTAssertTrue(actions.contains { action in
            if case .capabilityConfirmed(let cap) = action {
                return cap == .listSessions
            }
            return false
        })
    }
    
    func testSessionListWithItemsKey() {
        let result: ACP.Value = .object([
            "items": .array([
                .object(["sessionId": .string("item-1")])
            ])
        ])
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/list",
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .sessionListReceived(let listResult) = action {
                return listResult.sessions.count == 1
            }
            return false
        })
    }
    
    func testSessionListCwdTransform() {
        let result: ACP.Value = .object([
            "sessions": .array([
                .object([
                    "sessionId": .string("session-1"),
                    "cwd": .string("/path/to/secret")
                ])
            ])
        ])
        
        let context = ACPResponseDispatchContext(
            cwdTransform: { _ in "/redacted" }
        )
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/list",
            context: context
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .sessionListReceived(let listResult) = action {
                return listResult.sessions.first?.cwd == "/redacted"
            }
            return false
        })
    }
    
    // MARK: - Error Dispatch Tests
    
    func testErrorDispatchMethodNotFound() {
        let actions = ACPResponseDispatcher.dispatchError(
            code: -32601,
            message: "Method not found",
            method: "session/load"
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .rpcError(let info) = action {
                return info.code == -32601 && info.method == "session/load"
            }
            return false
        })
        XCTAssertTrue(actions.contains { action in
            if case .capabilityDisabled(let cap) = action {
                return cap == .loadSession
            }
            return false
        })
    }
    
    func testErrorDispatchResumeNotFound() {
        let actions = ACPResponseDispatcher.dispatchError(
            code: -32601,
            message: "Method not found",
            method: "session/resume"
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .capabilityDisabled(let cap) = action {
                return cap == .resumeSession
            }
            return false
        })
    }
    
    func testErrorDispatchListNotFound() {
        let actions = ACPResponseDispatcher.dispatchError(
            code: -32601,
            message: "Method not found",
            method: "session/list"
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .capabilityDisabled(let cap) = action {
                return cap == .listSessions
            }
            return false
        })
    }
    
    func testErrorDispatchOtherCode() {
        let actions = ACPResponseDispatcher.dispatchError(
            code: -32600,
            message: "Invalid request",
            method: "session/load"
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .rpcError = action {
                return true
            }
            return false
        })
        // Should not disable capability for non-method-not-found errors
        XCTAssertFalse(actions.contains { action in
            if case .capabilityDisabled = action {
                return true
            }
            return false
        })
    }
    
    // MARK: - Session with Modes Tests
    
    func testSessionNewWithModes() {
        let result: ACP.Value = .object([
            "sessionId": .string("session-with-modes"),
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
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/new",
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .sessionActivated(let activation) = action {
                return activation.modes?.currentModeId == "code" &&
                       activation.modes?.availableModes.count == 1
            }
            return false
        })
    }
    
    // MARK: - Fallback Session ID Dispatch
    
    func testFallbackSessionIdFromOtherMethod() {
        let result: ACP.Value = .object([
            "session": .string("fallback-id"),
            "cwd": .string("/path")
        ])
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/prompt",  // Not a session method
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .sessionActivated(let activation) = action {
                return activation.sessionId == "fallback-id"
            }
            return false
        })
        // Should not mark materialized for non-session methods
        XCTAssertFalse(actions.contains { action in
            if case .sessionMaterialized = action {
                return true
            }
            return false
        })
    }
    
    // MARK: - Empty/Nil Result Tests
    
    func testEmptyResultNoActions() {
        let result: ACP.Value = .object([:])
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/cancel",
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertTrue(actions.isEmpty)
    }
    
    func testNilResultNoSessionActivation() {
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: nil,
            method: "session/new",
            context: ACPResponseDispatchContext()
        )
        
        XCTAssertFalse(actions.contains { action in
            if case .sessionActivated = action {
                return true
            }
            return false
        })
    }
    
    // MARK: - Pendng CWD Fallback Tests
    
    func testPendingCwdUsedAsFallback() {
        let result: ACP.Value = .object([
            "sessionId": .string("new-session")
            // No cwd in response
        ])
        
        let context = ACPResponseDispatchContext(
            pendingCwd: "/pending/working/dir"
        )
        
        let actions = ACPResponseDispatcher.dispatchSuccess(
            result: result,
            method: "session/new",
            context: context
        )
        
        XCTAssertTrue(actions.contains { action in
            if case .sessionActivated(let activation) = action {
                return activation.cwd == "/pending/working/dir"
            }
            return false
        })
    }
}