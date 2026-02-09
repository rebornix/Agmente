import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct URLSessionWebSocketProvider: WebSocketProviding {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    public func makeConnection(url: URL) -> WebSocketConnection {
        URLSessionWebSocketConnection(url: url, session: session)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init(url: URL, session: URLSession) {
        self.url = url
        self.session = session
    }

    func connect(headers: [String: String]) async throws {
        var request = URLRequest(url: url)
        headers.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    func send(text: String) async throws {
        guard let task else { throw WebSocketError.notConnected }
        try await task.send(.string(text))
    }

    func receive() async throws -> WebSocketEvent {
        guard let task else { throw WebSocketError.notConnected }
        let message = try await task.receive()
        switch message {
        case .data(let data):
            return .binary(data)
        case .string(let text):
            return .text(text)
        @unknown default:
            return .closed(WebSocketCloseReason(code: URLSessionWebSocketTask.CloseCode.abnormalClosure.rawValue, reason: "Unknown event"))
        }
    }

    func close() async {
        guard let task else { return }
        task.cancel(with: .goingAway, reason: nil)
    }

    func ping() async throws {
        guard let task else { throw WebSocketError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}