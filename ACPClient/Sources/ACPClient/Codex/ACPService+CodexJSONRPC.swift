import ACP
import Foundation

public extension ACPService {
    /// Codex compatibility helper that sends a legacy JSON-RPC envelope.
    func sendMessage(_ message: JSONRPCMessage) async throws {
        try await sendMessage(message.acpWireMessage)
    }

    /// Codex compatibility helper that returns JSON-RPC-shaped results.
    func callJSONRPC(method: String, params: JSONValue? = nil) async throws -> JSONRPCResponse {
        let response = try await call(method: method, params: params?.acpValue)
        guard let jsonResponse = JSONRPCResponse(response) else {
            throw ACPServiceError.unsupportedMessage
        }
        return jsonResponse
    }
}