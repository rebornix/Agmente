import ACP
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct URLSessionWebSocketProvider: WebSocketProviding {
    public init() {}

    public func makeConnection(url: URL) -> WebSocketConnection {
        URLSessionWebSocketConnection(url: url)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let url: URL
    private var transport: WebSocketTransport?
    private var iterator: AsyncThrowingStream<Data, Swift.Error>.AsyncIterator?

    init(url: URL) {
        self.url = url
    }

    func connect(headers: [String: String]) async throws {
        let configuration = WebSocketConfiguration(
            url: url,
            headers: headers,
            pingInterval: nil,
            appendNewline: false,
            authTokenProvider: nil
        )
        let transport = WebSocketTransport(configuration: configuration)
        self.transport = transport
        try await transport.connect()
        iterator = nil
    }

    func send(text: String) async throws {
        guard let transport else { throw WebSocketError.notConnected }
        let data = Data(text.utf8)
        try await transport.send(data)
    }

    func receive() async throws -> WebSocketEvent {
        guard let transport else { throw WebSocketError.notConnected }
        if iterator == nil {
            iterator = await transport.receive().makeAsyncIterator()
        }
        if let data = try await iterator?.next() {
            return .binary(data)
        }
        return .closed(WebSocketCloseReason(code: URLSessionWebSocketTask.CloseCode.normalClosure.rawValue, reason: "Stream closed"))
    }

    func close() async {
        guard let transport else { return }
        await transport.disconnect()
        self.transport = nil
        iterator = nil
    }

    func ping() async throws {
        guard let transport else { throw WebSocketError.notConnected }
        try await transport.ping()
    }
}