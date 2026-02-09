import ACP
import Foundation

enum ACPMessageBridge {
    static func decodeMessage(from data: Data, decoder: JSONDecoder) throws -> ACPWireMessage {
        try decoder.decode(ACPWireMessage.self, from: data)
    }
}