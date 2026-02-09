import Foundation
import XCTest
@testable import ACPClient
import ACPClientMocks

@MainActor
final class ACPClientManagerRaceTests: XCTestCase {
    
    // A mock factory that returns services with specific mock connections
    class MockServiceFactory {
        var connections: [MockWebSocketConnection] = []
        
        func makeService(config: ACPClientConfiguration, encoder: JSONEncoder) -> ACPService {
            let connection: MockWebSocketConnection
            if !connections.isEmpty {
                connection = connections.removeFirst()
            } else {
                connection = MockWebSocketConnection()
            }
            
            let provider = MockWebSocketProvider(connection: connection)
            let client = ACPClient(
                configuration: config,
                socketProvider: provider,
                logger: NoOpLogger(),
                encoder: encoder
            )
            return ACPService(client: client)
        }
    }

    func testDisconnectConnectRace() async {
        let suiteName = "test-race-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        
        let factory = MockServiceFactory()
        let connection1 = MockWebSocketConnection()
        let connection2 = MockWebSocketConnection()
        factory.connections = [connection1, connection2]
        
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: factory.makeService
        )
        
        let config1 = ACPConnectionConfig(endpoint: URL(string: "ws://server1.com")!)
        let config2 = ACPConnectionConfig(endpoint: URL(string: "ws://server2.com")!)
        
        // 1. Establish first connection
        let success1 = await manager.connectAndWait(config: config1)
        XCTAssertTrue(success1)
        XCTAssertEqual(manager.connectionState, .connected)
        let service1 = manager.service
        XCTAssertNotNil(service1)
        
        // 2. Trigger Disconnect and Connect immediately
        // This simulates the user switching servers rapidly
        
        manager.disconnect() // Schedules Task D
        
        // Helper to wait a tiny bit to ensure Task D is scheduled but maybe not finished?
        // Actually since we are on MainActor, the synchronous parts run first.
        // disconnect() sync part runs. serviceToDisconnect captured.
        // connect() sync part runs. manager.service updated to service2.
        
        let connectPromise = expectation(description: "Connect 2 finished")
        var success2 = false
        
        manager.connect(config: config2) { result in
            success2 = result
            connectPromise.fulfill()
        }
        
        // 3. Allow tasks to run
        await fulfillment(of: [connectPromise], timeout: 2.0)
        
        // 4. Verification
        XCTAssertTrue(success2, "Second connection should succeed")
        XCTAssertNotNil(manager.service, "Service should not be nil")
        XCTAssertTrue(manager.service !== service1, "Service should be the new one")
        XCTAssertEqual(manager.connectionState, .connected, "State should be connected")
        
        // 5. Verify that the old service did disconnect
        // (MockWebSocketConnection doesn't expose closed status easily but we can infer)
        // Check if old service events are ignored.
        
        // Simulate an error or state change on the OLD connection (service1)
        // If the fix works, these should be ignored by the manager
        manager.acpService(service1!, didChangeState: .disconnected)
        
        XCTAssertEqual(manager.connectionState, .connected, "State should NOT change to disconnected when old service disconnects")
        
        // Cleanup
        manager.disconnect()
    }
}