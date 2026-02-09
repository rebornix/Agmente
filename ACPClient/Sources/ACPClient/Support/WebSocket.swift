import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol WebSocketProviding: Sendable {
    func makeConnection(url: URL) -> WebSocketConnection
}

public protocol WebSocketConnection: AnyObject, Sendable {
    func connect(headers: [String: String]) async throws
    func send(text: String) async throws
    func receive() async throws -> WebSocketEvent
    func close() async
    func ping() async throws
}

public enum WebSocketEvent: Equatable {
    case connected
    case text(String)
    case binary(Data)
    case closed(WebSocketCloseReason)
}

public struct WebSocketCloseReason: Equatable {
    public var code: Int
    public var reason: String?

    public init(code: Int, reason: String? = nil) {
        self.code = code
        self.reason = reason
    }
}

public enum WebSocketError: Error {
    case notConnected
}