import Foundation

public struct AppServerClientConfiguration {
    public typealias TokenProvider = () async throws -> String

    public var endpoint: URL
    public var authTokenProvider: TokenProvider?
    public var additionalHeaders: [String: String]
    public var pingInterval: TimeInterval?
    /// Append a trailing newline to outbound JSON (useful for stdio bridges that expect line-delimited JSON).
    public var appendNewline: Bool
    /// Include the `"jsonrpc":"2.0"` header on outgoing messages.
    public var includeJSONRPCHeader: Bool

    public init(
        endpoint: URL,
        authTokenProvider: TokenProvider? = nil,
        additionalHeaders: [String: String] = [:],
        pingInterval: TimeInterval? = nil,
        appendNewline: Bool = true,
        includeJSONRPCHeader: Bool = false
    ) {
        self.endpoint = endpoint
        self.authTokenProvider = authTokenProvider
        self.additionalHeaders = additionalHeaders
        self.pingInterval = pingInterval
        self.appendNewline = appendNewline
        self.includeJSONRPCHeader = includeJSONRPCHeader
    }
}