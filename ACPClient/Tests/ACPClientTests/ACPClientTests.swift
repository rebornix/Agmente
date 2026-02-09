import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ACPClient
import ACPClientMocks

struct ACPClientTests {
    @Test func encodesAndDecodesJSONRPCMessages() async throws {
        let request = ACPWireMessage.request(.init(id: .string("1"), method: "initialize", params: .object(["agent": .string("demo")])) )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ACPWireMessage.self, from: data)
        #expect(decoded == request)

        let response = ACPWireMessage.response(.init(id: .int(1), result: .object(["status": .string("ok")])) )
        let responseData = try JSONEncoder().encode(response)
        let decodedResponse = try JSONDecoder().decode(ACPWireMessage.self, from: responseData)
        #expect(decodedResponse == response)

        let notification = ACPWireMessage.notification(.init(method: "acp/notify", params: .array([.string("hello")])) )
        let notificationData = try JSONEncoder().encode(notification)
        let decodedNotification = try JSONDecoder().decode(ACPWireMessage.self, from: notificationData)
        #expect(decodedNotification == notification)
    }

    @Test func connectsAndReceivesMessages() async throws {
        let provider = MockWebSocketProvider()
        let delegate = CapturingDelegate()
        let configuration = ACPClientConfiguration(endpoint: URL(string: "wss://example.com/socket")!)
        let client = ACPClient(configuration: configuration, socketProvider: provider)
        client.delegate = delegate

        try await client.connect()

        let incoming = ACPWireMessage.notification(.init(method: "acp/notification", params: .object(["value": .string("ping")])) )
        let encoded = try JSONEncoder().encode(incoming)
        let text = String(decoding: encoded, as: UTF8.self)
        provider.connection.enqueue(.text(text))
        provider.connection.enqueue(.closed(.init(code: URLSessionWebSocketTask.CloseCode.normalClosure.rawValue)))

        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(delegate.states.contains(.connected))
        #expect(delegate.messages == [incoming])
    }

    @Test func buildsAuthorizationHeadersFromTokenProvider() async throws {
        let provider = MockWebSocketProvider()
        let configuration = ACPClientConfiguration(
            endpoint: URL(string: "wss://example.com/socket")!,
            authTokenProvider: { "abc123" },
            additionalHeaders: ["X-Test": "1"]
        )
        let client = ACPClient(configuration: configuration, socketProvider: provider)
        try await client.connect()

        #expect(provider.connection.receivedHeaders["Authorization"] == "Bearer abc123")
        #expect(provider.connection.receivedHeaders["X-Test"] == "1")
    }

    @Test func sendsPingWhenConfigured() async throws {
        let connection = MockWebSocketConnection()
        let provider = MockWebSocketProvider(connection: connection)
        let configuration = ACPClientConfiguration(endpoint: URL(string: "wss://example.com/socket")!, pingInterval: 0.01)
        let client = ACPClient(configuration: configuration, socketProvider: provider)
        try await client.connect()

        try await Task.sleep(nanoseconds: 30_000_000)
        await client.disconnect()

        #expect(connection.pingCount >= 2)
    }

    @Test func canDisableEscapedForwardSlashesInOutboundJSON() async throws {
        let connection = MockWebSocketConnection()
        let provider = MockWebSocketProvider(connection: connection)
        let configuration = ACPClientConfiguration(
            endpoint: URL(string: "wss://example.com/socket")!,
            appendNewline: false
        )
        let client = ACPClient(configuration: configuration, socketProvider: provider)

        try await client.connect()
        client.setWithoutEscapingSlashesEnabled(true)

        let request = ACPWireMessage.request(.init(id: .int(1), method: "session/list", params: .object([:])))
        try await client.send(request)

        #expect(connection.sentTexts.count == 1)
        let sent = connection.sentTexts[0]
        #expect(sent.contains("\"method\":\"session/list\""))
        #expect(!sent.contains("session\\/list"))
    }
}