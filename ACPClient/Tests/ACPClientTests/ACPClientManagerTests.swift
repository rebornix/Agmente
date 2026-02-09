import Foundation
import XCTest
@testable import ACPClient
import ACPClientMocks

@MainActor
final class ACPClientManagerTests: XCTestCase {
    private struct TestError: Error {}

    private func extractRequestId(from text: String) -> Int? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else {
            return nil
        }
        return id
    }

    private func waitForSentText(
        connection: MockWebSocketConnection,
        predicate: (String) -> Bool,
        attempts: Int = 50
    ) async -> String? {
        for _ in 0..<attempts {
            if let match = connection.sentTexts.first(where: predicate) {
                return match
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    private func makeManager(
        defaults: UserDefaults,
        connection: MockWebSocketConnection
    ) -> ACPClientManager {
        let factory: (ACPClientConfiguration, JSONEncoder) -> ACPService = { config, encoder in
            let provider = MockWebSocketProvider(connection: connection)
            let client = ACPClient(
                configuration: config,
                socketProvider: provider,
                logger: NoOpLogger(),
                encoder: encoder
            )
            return ACPService(client: client)
        }
        return ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: factory
        )
    }

    // MARK: - Client ID Persistence

    func testGeneratesAndPersistsClientId() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)

        XCTAssertFalse(manager.clientId.isEmpty, "Should generate a non-empty client ID")
        XCTAssertEqual(defaults.string(forKey: "ACPClientManager.clientId"), manager.clientId)
    }

    func testReusesPersistedClientId() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let existingId = "test-client-id-123"
        defaults.set(existingId, forKey: "ACPClientManager.clientId")

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)

        XCTAssertEqual(manager.clientId, existingId)
    }

    func testUsesProvidedClientId() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set("stored-id", forKey: "ACPClientManager.clientId")
        let providedId = "provided-id-456"

        let manager = ACPClientManager(defaults: defaults, clientId: providedId, shouldStartNetworkMonitoring: false)

        XCTAssertEqual(manager.clientId, providedId, "Should use provided client ID over stored")
    }

    // MARK: - Initial State

    func testInitialState() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)

        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertFalse(manager.isConnecting)
        XCTAssertTrue(manager.isNetworkAvailable) // Default before monitoring starts
        XCTAssertNil(manager.service)
        XCTAssertNil(manager.lastConnectedAt)
    }

    func testLoadsPersistedLastConnectedAt() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let timestamp = Date().timeIntervalSince1970 - 3600 // 1 hour ago
        defaults.set(timestamp, forKey: "ACPClientManager.lastConnectedAt")

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)

        XCTAssertNotNil(manager.lastConnectedAt)
        XCTAssertEqual(manager.lastConnectedAt!.timeIntervalSince1970, timestamp, accuracy: 1.0)
    }

    // MARK: - Configuration

    func testConnectionConfigDefaults() {
        let url = URL(string: "ws://localhost:8765")!
        let config = ACPConnectionConfig(endpoint: url)

        XCTAssertEqual(config.endpoint, url)
        XCTAssertNil(config.authToken)
        XCTAssertNil(config.cloudflareAccessClientId)
        XCTAssertNil(config.cloudflareAccessClientSecret)
        XCTAssertFalse(config.requiresUnescapedSlashes)
        XCTAssertEqual(config.pingInterval, 15)
    }

    func testConnectionConfigWithAllOptions() {
        let url = URL(string: "wss://secure.example.com")!
        let config = ACPConnectionConfig(
            endpoint: url,
            authToken: "bearer-token",
            cloudflareAccessClientId: "cf-id",
            cloudflareAccessClientSecret: "cf-secret",
            requiresUnescapedSlashes: true,
            pingInterval: 30
        )

        XCTAssertEqual(config.endpoint, url)
        XCTAssertEqual(config.authToken, "bearer-token")
        XCTAssertEqual(config.cloudflareAccessClientId, "cf-id")
        XCTAssertEqual(config.cloudflareAccessClientSecret, "cf-secret")
        XCTAssertTrue(config.requiresUnescapedSlashes)
        XCTAssertEqual(config.pingInterval, 30)
    }

    // MARK: - Reconnect Defaults

    func testDefaultReconnectSettings() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)

        XCTAssertEqual(manager.maxReconnectAttempts, 3)
        XCTAssertEqual(manager.reconnectBaseDelay, 1.0)
        XCTAssertEqual(manager.healthCheckTimeout, 8.0)
    }

    func testCustomReconnectSettings() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.maxReconnectAttempts = 5
        manager.reconnectBaseDelay = 2.0
        manager.healthCheckTimeout = 10.0

        XCTAssertEqual(manager.maxReconnectAttempts, 5)
        XCTAssertEqual(manager.reconnectBaseDelay, 2.0)
        XCTAssertEqual(manager.healthCheckTimeout, 10.0)
    }

    // MARK: - Disconnect

    func testDisconnectResetsState() async {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.disconnect()

        // Give async disconnect time to complete
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertFalse(manager.isConnecting)
        XCTAssertNil(manager.service)
    }

    // MARK: - Delegate

    func testDelegateReceivesLogMessages() async {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let mockDelegate = MockClientManagerDelegate()
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.delegate = mockDelegate

        // Disconnect should log - trigger via disconnect which doesn't require a connection
        manager.disconnect()

        // Give async operations time to complete
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(mockDelegate.stateChanges.last, .disconnected)
    }

    // MARK: - Lifecycle

    func testConnectAndWaitUpdatesStateAndLastConnectedAt() async {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let connection = MockWebSocketConnection()
        let manager = makeManager(defaults: defaults, connection: connection)
        let config = ACPConnectionConfig(endpoint: URL(string: "ws://localhost:8765")!)

        let success = await manager.connectAndWait(config: config)

        XCTAssertTrue(success)
        XCTAssertEqual(manager.connectionState, .connected)
        XCTAssertNotNil(manager.lastConnectedAt)
        XCTAssertGreaterThan(defaults.double(forKey: "ACPClientManager.lastConnectedAt"), 0)

        manager.disconnect()
    }

    func testVerifyConnectionHealthPingsService() async {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let connection = MockWebSocketConnection()
        let manager = makeManager(defaults: defaults, connection: connection)
        let config = ACPConnectionConfig(endpoint: URL(string: "ws://localhost:8765")!)

        _ = await manager.connectAndWait(config: config)
        let pingCountBefore = connection.pingCount
        await manager.verifyConnectionHealth()

        XCTAssertGreaterThanOrEqual(connection.pingCount, pingCountBefore + 1)

        manager.disconnect()
    }

    func testInitializeAndWaitSetsInitialized() async {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let connection = MockWebSocketConnection()
        let manager = makeManager(defaults: defaults, connection: connection)
        let config = ACPConnectionConfig(endpoint: URL(string: "ws://localhost:8765")!)

        _ = await manager.connectAndWait(config: config)

        let payload = ACPInitializationPayload(
            protocolVersion: 1,
            clientName: "Test",
            clientVersion: "0.1",
            clientCapabilities: [:]
        )

        let task = Task { await manager.initializeAndWait(payload: payload) }

        guard let sent = await waitForSentText(connection: connection, predicate: { $0.contains("\"initialize\"") }) else {
            XCTFail("Expected initialize request to be sent")
            return
        }
        let id = extractRequestId(from: sent) ?? 1
        let response = """
        {"jsonrpc":"2.0","id":\(id),"result":{}}
        """
        connection.enqueue(.text(response))

        let success = await task.value
        XCTAssertTrue(success)
        XCTAssertTrue(manager.isInitialized)
        XCTAssertFalse(manager.isInitializing)

        manager.disconnect()
    }

    func testSessionTrackingResetClearsState() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)

        manager.markSessionMaterialized("session-1")
        manager.setResumingSession("session-1", isResuming: true)

        XCTAssertTrue(manager.isSessionMaterialized("session-1"))
        XCTAssertTrue(manager.isResumingSession("session-1"))

        manager.resetSessionState()

        XCTAssertFalse(manager.isSessionMaterialized("session-1"))
        XCTAssertFalse(manager.isResumingSession("session-1"))
    }

    func testFailedStateClearsConnectingFlag() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let connection = MockWebSocketConnection()
        let manager = makeManager(defaults: defaults, connection: connection)
        let service = ACPService(client: ACPClient(configuration: .init(endpoint: URL(string: "ws://localhost:8765")!)))
        manager.setServiceForTesting(service)

        manager.acpService(service, didChangeState: .failed(TestError()))

        if case .failed = manager.connectionState {
        } else {
            XCTFail("Expected failed connection state")
        }
        XCTAssertFalse(manager.isConnecting)
    }
}

// MARK: - Mock Delegate

@MainActor
private final class MockClientManagerDelegate: ACPClientManagerDelegate {
    var stateChanges: [ACPConnectionState] = []
    var networkChanges: [Bool] = []
    var errors: [Error] = []
    var logMessages: [String] = []
    var createdServices: [ACPService] = []

    func clientManager(_ manager: ACPClientManager, didChangeState state: ACPConnectionState) {
        stateChanges.append(state)
    }

    func clientManager(_ manager: ACPClientManager, didChangeNetworkAvailability available: Bool) {
        networkChanges.append(available)
    }

    func clientManager(_ manager: ACPClientManager, didEncounterError error: Error) {
        errors.append(error)
    }

    func clientManager(_ manager: ACPClientManager, didLog message: String) {
        logMessages.append(message)
    }

    func clientManager(_ manager: ACPClientManager, didCreateService service: ACPService) {
        createdServices.append(service)
    }
}