import XCTest
import ACP
@testable import Agmente
import ACPClient

/// Phase 1 & 2 tests for per-session SessionViewModel isolation.
/// These tests verify that the bug described in issue #16 is fixed:
/// tool confirmations stay with their session when switching sessions.
///
/// Phase 2 changes: SessionViewModels are now managed by ServerViewModel,
/// so tests verify behavior through currentSessionViewModel rather than
/// accessing internal dictionaries directly.
@MainActor
final class SessionIsolationTests: XCTestCase {

    // MARK: - Test Infrastructure

    private var model: AppViewModel!
    private var testServerId: UUID!

    override func setUp() {
        super.setUp()
        // Create a test instance without auto-connect
        model = AppViewModel(
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        // Phase 2: Add a test server so currentSessionViewModel works
        model.addServer(
            name: "Test Server",
            scheme: "ws",
            host: "localhost:9999",
            token: "",
            cfAccessClientId: "",
            cfAccessClientSecret: "",
            workingDirectory: "/tmp"
        )
        // The addServer method selects the server and sets selectedServerId
        testServerId = model.selectedServerId!
    }

    override func tearDown() {
        model = nil
        testServerId = nil
        super.tearDown()
    }

    // MARK: - Phase 1 & 2: Session Isolation Tests

    /// Test that tool confirmation requests stay with their session when switching sessions.
    /// This is the core bug that Phase 1 fixes.
    func testToolConfirmation_StaysWithSession() {
        // Given: Two sessions
        let sessionIdA = "session-a"
        let sessionIdB = "session-b"

        // Create view models for both sessions by switching to them
        model.selectedServerViewModel?.selectedSessionId = sessionIdA
        let viewModelA = model.selectedServerViewModel?.currentSessionViewModel
        XCTAssertNotNil(viewModelA, "ViewModelA should be created")

        model.selectedServerViewModel?.selectedSessionId = sessionIdB
        let viewModelB = model.selectedServerViewModel?.currentSessionViewModel
        XCTAssertNotNil(viewModelB, "ViewModelB should be created")

        // Verify they are different instances
        XCTAssertFalse(viewModelA === viewModelB, "Each session should have its own ViewModel instance")

        // When: Add a pending permission request to session A
        model.selectedServerViewModel?.selectedSessionId = sessionIdA
        // Simulate permission request (would normally come from handlePermissionRequest)
        let mockRequest = ACP.AnyRequest(
            id: .string("req-1"),
            method: "acp/permission/request",
            params: .object([
                "sessionId": .string(sessionIdA),
                "toolCallId": .string("tool-1"),
                "title": .string("Read file"),
                "kind": .string("read"),
                "options": .array([
                    .object([
                        "id": .string("allow"),
                        "name": .string("Allow")
                    ])
                ])
            ])
        )
        viewModelA?.handlePermissionRequest(mockRequest)

        // Then: Switch to session B
        model.selectedServerViewModel?.selectedSessionId = sessionIdB

        // Verify: Session B's view model should be different from A
        let currentViewModelB = model.selectedServerViewModel?.currentSessionViewModel
        XCTAssertNotNil(currentViewModelB, "Session B's view model should exist")
        XCTAssertFalse(viewModelA === currentViewModelB, "View models should remain distinct")

        // Switch back to session A
        model.selectedServerViewModel?.selectedSessionId = sessionIdA

        // Verify: Session A's view model is restored (same instance)
        let currentViewModelA = model.selectedServerViewModel?.currentSessionViewModel
        XCTAssertTrue(viewModelA === currentViewModelA, "Session A should return the same view model instance")
    }

    /// Test that chat messages are preserved when switching sessions.
    func testSessionSwitch_PreservesMessages() {
        let sessionIdA = "session-a"
        let sessionIdB = "session-b"

        // Session A: Add messages
        model.selectedServerViewModel?.selectedSessionId = sessionIdA
        if let viewModelA = model.selectedServerViewModel?.currentSessionViewModel {
            viewModelA.setSessionContext(serverId: testServerId, sessionId: sessionIdA)
            viewModelA.addUserMessage(content: "Message in session A", images: [])
        }

        // Verify session A has 1 message
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.count, 1)
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.first?.content, "Message in session A")

        // Session B: Add different message
        model.selectedServerViewModel?.selectedSessionId = sessionIdB
        if let viewModelB = model.selectedServerViewModel?.currentSessionViewModel {
            viewModelB.setSessionContext(serverId: testServerId, sessionId: sessionIdB)
            viewModelB.addUserMessage(content: "Message in session B", images: [])
        }

        // Verify session B has 1 message
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.count, 1)
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.first?.content, "Message in session B")

        // Switch back to session A
        model.selectedServerViewModel?.selectedSessionId = sessionIdA

        // Verify session A still has its original message
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.count, 1)
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.first?.content, "Message in session A")
    }

    /// Test that placeholder session IDs are properly migrated to resolved IDs.
    /// Note: In Phase 2, migration is handled internally by ServerViewModel.
    /// This test verifies the behavior through currentSessionViewModel.
    func testPlaceholderMigration_PreservesViewModel() {
        let placeholderId = "placeholder-123"

        // Create a session with placeholder ID
        model.selectedServerViewModel?.selectedSessionId = placeholderId
        if let viewModel = model.selectedServerViewModel?.currentSessionViewModel {
            viewModel.setSessionContext(serverId: testServerId, sessionId: placeholderId)
            viewModel.addUserMessage(content: "Message in placeholder", images: [])
        }

        // Capture the view model reference
        let originalViewModel = model.selectedServerViewModel?.currentSessionViewModel
        XCTAssertNotNil(originalViewModel)

        // Verify messages are present
        XCTAssertEqual(originalViewModel?.chatMessages.count, 1)
        XCTAssertEqual(originalViewModel?.chatMessages.first?.content, "Message in placeholder")

        // Switch away and back
        model.selectedServerViewModel?.selectedSessionId = "other-session"
        model.selectedServerViewModel?.selectedSessionId = placeholderId

        // Verify the same view model is returned (instance preserved)
        let restoredViewModel = model.selectedServerViewModel?.currentSessionViewModel
        XCTAssertTrue(originalViewModel === restoredViewModel, "Should be the same view model instance")

        // Verify messages are preserved
        XCTAssertEqual(restoredViewModel?.chatMessages.count, 1)
        XCTAssertEqual(restoredViewModel?.chatMessages.first?.content, "Message in placeholder")
    }

    /// Test that deleting a session cleans up its view model.
    func testDeleteSession_CleansUpViewModel() {
        let sessionId = "session-to-delete"

        // Create a session view model
        model.selectedServerViewModel?.selectedSessionId = sessionId
        let viewModel = model.selectedServerViewModel?.currentSessionViewModel
        XCTAssertNotNil(viewModel, "View model should be created")

        // Add a message to the session to verify it exists
        viewModel?.setSessionContext(serverId: testServerId, sessionId: sessionId)
        viewModel?.addUserMessage(content: "Test message", images: [])
        XCTAssertEqual(viewModel?.chatMessages.count, 1)

        // Delete the session
        model.deleteSession(sessionId)

        // After deleting the selected session, selecting it again should give a fresh view model
        // (The old view model instance should be cleaned up)
        model.selectedServerViewModel?.selectedSessionId = sessionId
        let newViewModel = model.selectedServerViewModel?.currentSessionViewModel

        // New view model should have no messages (fresh instance)
        XCTAssertEqual(newViewModel?.chatMessages.count ?? 0, 0, "New view model should be fresh with no messages")
    }

    /// Test that current mode is isolated per session.
    func testCurrentMode_IsolatedPerSession() {
        let sessionIdA = "session-a"
        let sessionIdB = "session-b"

        // Session A: Set mode to "code"
        model.selectedServerViewModel?.selectedSessionId = sessionIdA
        model.selectedServerViewModel?.currentSessionViewModel?.setSessionContext(serverId: testServerId, sessionId: sessionIdA)
        model.selectedServerViewModel?.currentSessionViewModel?.setCurrentModeId("code")
        model.selectedServerViewModel?.currentSessionViewModel?.cacheCurrentMode(serverId: testServerId, sessionId: sessionIdA)

        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.currentModeId, "code")

        // Session B: Set mode to "ask"
        model.selectedServerViewModel?.selectedSessionId = sessionIdB
        model.selectedServerViewModel?.currentSessionViewModel?.setSessionContext(serverId: testServerId, sessionId: sessionIdB)
        model.selectedServerViewModel?.currentSessionViewModel?.setCurrentModeId("ask")
        model.selectedServerViewModel?.currentSessionViewModel?.cacheCurrentMode(serverId: testServerId, sessionId: sessionIdB)

        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.currentModeId, "ask")

        // Switch back to session A
        model.selectedServerViewModel?.selectedSessionId = sessionIdA

        // Verify session A still has "code" mode
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.currentModeId, "code")
    }

    /// Test that streaming state is isolated per session.
    func testStreamingState_IsolatedPerSession() {
        let sessionIdA = "session-a"
        let sessionIdB = "session-b"

        // Session A: Start streaming
        model.selectedServerViewModel?.selectedSessionId = sessionIdA
        model.selectedServerViewModel?.currentSessionViewModel?.setSessionContext(serverId: testServerId, sessionId: sessionIdA)
        model.selectedServerViewModel?.currentSessionViewModel?.startNewStreamingResponse()

        XCTAssertTrue(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.last?.isStreaming ?? false)

        // Session B: Add non-streaming message
        model.selectedServerViewModel?.selectedSessionId = sessionIdB
        model.selectedServerViewModel?.currentSessionViewModel?.setSessionContext(serverId: testServerId, sessionId: sessionIdB)
        model.selectedServerViewModel?.currentSessionViewModel?.addUserMessage(content: "Complete message", images: [])

        XCTAssertFalse(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.last?.isStreaming ?? true)

        // Switch back to session A
        model.selectedServerViewModel?.selectedSessionId = sessionIdA

        // Verify session A still has streaming message
        XCTAssertTrue(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.last?.isStreaming ?? false)
    }

    /// Test that view models are lazily created.
    func testViewModelCreation_IsLazy() {
        let sessionId = "lazy-session"

        // With test server selected but no session, currentSessionViewModel returns nil
        // because there's no selectedSessionId yet (we set one in setUp but let's test with a new one)
        model.selectedServerViewModel?.selectedSessionId = nil
        XCTAssertNil(model.selectedServerViewModel?.currentSessionViewModel, "No view model without selected session")

        // Access currentSessionViewModel (should create it)
        model.selectedServerViewModel?.selectedSessionId = sessionId
        let viewModel = model.selectedServerViewModel?.currentSessionViewModel

        XCTAssertNotNil(viewModel, "View model should be created on first access")
    }

    /// Test that multiple sessions can coexist with their own state.
    func testMultipleSessions_CoexistWithIsolatedState() {
        let sessions = ["session-1", "session-2", "session-3"]
        var viewModels: [String: ACPSessionViewModel] = [:]

        // Create and populate multiple sessions
        for (index, sessionId) in sessions.enumerated() {
            model.selectedServerViewModel?.selectedSessionId = sessionId
            if let viewModel = model.selectedServerViewModel?.currentSessionViewModel {
                viewModel.setSessionContext(serverId: testServerId, sessionId: sessionId)
                viewModel.addUserMessage(content: "Message \(index + 1)", images: [])
                viewModel.setCurrentModeId("mode-\(index + 1)")
                viewModels[sessionId] = viewModel
            }
        }

        // Verify all sessions were created
        XCTAssertEqual(viewModels.count, 3)

        // Verify each session has its own state by switching to each
        for (index, sessionId) in sessions.enumerated() {
            model.selectedServerViewModel?.selectedSessionId = sessionId
            let viewModel = model.selectedServerViewModel?.currentSessionViewModel
            XCTAssertNotNil(viewModel)
            XCTAssertEqual(viewModel?.chatMessages.count, 1)
            XCTAssertEqual(viewModel?.chatMessages.first?.content, "Message \(index + 1)")
            XCTAssertEqual(viewModel?.currentModeId, "mode-\(index + 1)")

            // Verify it's the same instance we created earlier
            XCTAssertTrue(viewModel === viewModels[sessionId], "Should return the same view model instance")
        }
    }

    /// Test that isStreaming computed property works correctly with per-session view models.
    func testIsStreaming_ReflectsCurrentSession() {
        let streamingSessionId = "streaming-session"
        let idleSessionId = "idle-session"

        // Streaming session: Add streaming message
        model.selectedServerViewModel?.selectedSessionId = streamingSessionId
        model.selectedServerViewModel?.currentSessionViewModel?.setSessionContext(serverId: testServerId, sessionId: streamingSessionId)
        model.selectedServerViewModel?.currentSessionViewModel?.startNewStreamingResponse()

        XCTAssertTrue(model.selectedServerViewModel?.isStreaming ?? false, "Should be streaming when current session has streaming message")

        // Idle session: Add complete message
        model.selectedServerViewModel?.selectedSessionId = idleSessionId
        model.selectedServerViewModel?.currentSessionViewModel?.setSessionContext(serverId: testServerId, sessionId: idleSessionId)
        model.selectedServerViewModel?.currentSessionViewModel?.addUserMessage(content: "Complete", images: [])

        XCTAssertFalse(model.selectedServerViewModel?.isStreaming ?? false, "Should not be streaming when current session has no streaming messages")

        // Switch back to streaming session
        model.selectedServerViewModel?.selectedSessionId = streamingSessionId

        XCTAssertTrue(model.selectedServerViewModel?.isStreaming ?? false, "Should be streaming again when switching back to streaming session")
    }
}