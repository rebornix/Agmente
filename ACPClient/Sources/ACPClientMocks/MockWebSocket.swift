import Foundation
import ACPClient

public final class MockWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    public enum MockError: Error { case noEvent }

    public private(set) var isConnected = false
    public private(set) var sentTexts: [String] = []
    public private(set) var pingCount: Int = 0
    public private(set) var receivedHeaders: [String: String] = [:]
    private var events: [WebSocketEvent] = []

    public init() {}

    public func connect(headers: [String : String]) async throws {
        receivedHeaders = headers
        isConnected = true
    }

    public func send(text: String) async throws {
        sentTexts.append(text)
    }

    public func receive() async throws -> WebSocketEvent {
        while events.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_00)
        }
        return events.removeFirst()
    }

    public func close() async {
        isConnected = false
    }

    public func ping() async throws {
        pingCount += 1
    }

    public func enqueue(_ event: WebSocketEvent) {
        events.append(event)
    }
}

public struct MockWebSocketProvider: WebSocketProviding {
    public let connection: MockWebSocketConnection

    public init(connection: MockWebSocketConnection = MockWebSocketConnection()) {
        self.connection = connection
    }

    public func makeConnection(url: URL) -> WebSocketConnection {
        connection
    }
}

public final class CapturingDelegate: ACPClientDelegate {
    public private(set) var states: [ACPConnectionState] = []
    public private(set) var messages: [ACPWireMessage] = []
    public private(set) var errors: [Error] = []

    public init() {}

    public func acpClient(_ client: ACPClient, didChangeState state: ACPConnectionState) {
        states.append(state)
    }

    public func acpClient(_ client: ACPClient, didReceiveMessage message: ACPWireMessage) {
        messages.append(message)
    }

    public func acpClient(_ client: ACPClient, didEncounterError error: any Error) {
        errors.append(error)
    }
}