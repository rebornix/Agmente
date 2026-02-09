import Foundation

public struct ACPClientConfiguration {
    public typealias TokenProvider = () async throws -> String

    public var endpoint: URL
    public var authTokenProvider: TokenProvider?
    public var additionalHeaders: [String: String]
    public var pingInterval: TimeInterval?
    /// Append a trailing newline to outbound JSON (useful for stdio bridges that expect line-delimited JSON).
    public var appendNewline: Bool

    public init(
        endpoint: URL,
        authTokenProvider: TokenProvider? = nil,
        additionalHeaders: [String: String] = [:],
        pingInterval: TimeInterval? = nil,
        appendNewline: Bool = true
    ) {
        self.endpoint = endpoint
        self.authTokenProvider = authTokenProvider
        self.additionalHeaders = additionalHeaders
        self.pingInterval = pingInterval
        self.appendNewline = appendNewline
    }
}