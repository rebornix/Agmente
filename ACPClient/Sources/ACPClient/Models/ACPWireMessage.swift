import ACP
import Foundation

public enum ACPWireMessage: Codable, Equatable, Sendable {
    case request(ACP.AnyRequest)
    case notification(ACP.AnyMessage)
    case response(ACP.AnyResponse)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let method = try container.decodeIfPresent(String.self, forKey: .method)
        let id: ACP.ID?
        if container.contains(.id) {
            if (try? container.decodeNil(forKey: .id)) == true {
                id = .null
            } else {
                id = try container.decode(ACP.ID.self, forKey: .id)
            }
        } else {
            id = nil
        }

        if let method {
            let params = try container.decodeIfPresent(ACP.Value.self, forKey: .params) ?? .null
            if let id, id != .null {
                self = .request(ACP.AnyRequest(id: id, method: method, params: params))
            } else {
                self = .notification(ACP.AnyMessage(method: method, params: params))
            }
            return
        }

        if let id {
            if let error = try container.decodeIfPresent(ACPError.self, forKey: .error) {
                self = .response(ACP.AnyResponse(id: id, error: error))
            } else {
                let result = try container.decodeIfPresent(ACP.Value.self, forKey: .result) ?? .null
                self = .response(ACP.AnyResponse(id: id, result: result))
            }
            return
        }

        if let error = try container.decodeIfPresent(ACPError.self, forKey: .error) {
            self = .response(ACP.AnyResponse(id: .null, error: error))
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown JSON-RPC shape"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .request(let request):
            try request.encode(to: encoder)
        case .notification(let notification):
            try notification.encode(to: encoder)
        case .response(let response):
            try response.encode(to: encoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
        case result
        case error
    }
}

public extension ACP.ID {
    static func int(_ value: Int) -> ACP.ID {
        .number(value)
    }
}

public extension ACP.Value {
    static func number(_ value: Double) -> ACP.Value {
        .double(value)
    }

    static func number(_ value: Int) -> ACP.Value {
        .int(value)
    }
}

public extension ACP.Response where M == ACP.AnyMethod {
    init(id: ACP.ID, result: ACP.Value? = nil) {
        self.init(id: id, result: result ?? .null)
    }

    var resultValue: ACP.Value? {
        if case .success(let value) = result {
            return value
        }
        return nil
    }

    var errorValue: ACPError? {
        if case .failure(let error) = result {
            return error
        }
        return nil
    }
}