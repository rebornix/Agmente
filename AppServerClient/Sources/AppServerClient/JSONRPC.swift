import Foundation

public enum JSONRPCID: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case int(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            let int = try container.decode(Int.self)
            self = .int(int)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        }
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let double = try? container.decode(Double.self) {
            self = .number(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            let object = try container.decode([String: JSONValue].self)
            self = .object(object)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct JSONRPCRequest: Codable, Equatable, Sendable {
    public var jsonrpc: String?
    public var id: JSONRPCID
    public var method: String
    public var params: JSONValue?

    public init(id: JSONRPCID, method: String, params: JSONValue? = nil, includeJSONRPC: Bool = false) {
        self.jsonrpc = includeJSONRPC ? "2.0" : nil
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification: Codable, Equatable, Sendable {
    public var jsonrpc: String?
    public var method: String
    public var params: JSONValue?

    public init(method: String, params: JSONValue? = nil, includeJSONRPC: Bool = false) {
        self.jsonrpc = includeJSONRPC ? "2.0" : nil
        self.method = method
        self.params = params
    }
}

public struct JSONRPCResponse: Codable, Equatable, Sendable {
    public var jsonrpc: String?
    public var id: JSONRPCID
    public var result: JSONValue?

    public init(id: JSONRPCID, result: JSONValue? = nil, includeJSONRPC: Bool = false) {
        self.jsonrpc = includeJSONRPC ? "2.0" : nil
        self.id = id
        self.result = result
    }
}

public struct JSONRPCErrorResponse: Codable, Equatable, Sendable {
    public struct Error: Codable, Equatable, Sendable {
        public var code: Int
        public var message: String
        public var data: JSONValue?

        public init(code: Int, message: String, data: JSONValue? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }
    }

    public var jsonrpc: String?
    public var id: JSONRPCID?
    public var error: Error

    public init(id: JSONRPCID?, error: Error, includeJSONRPC: Bool = false) {
        self.jsonrpc = includeJSONRPC ? "2.0" : nil
        self.id = id
        self.error = error
    }
}

public enum JSONRPCMessage: Codable, Equatable, Sendable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    case response(JSONRPCResponse)
    case error(JSONRPCErrorResponse)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let method = try container.decodeIfPresent(String.self, forKey: .method)
        let id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)
        let error = try container.decodeIfPresent(JSONRPCErrorResponse.Error.self, forKey: .error)
        if let method {
            if let id {
                let params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
                let request = JSONRPCRequest(id: id, method: method, params: params)
                self = .request(request)
            } else {
                let params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
                let notification = JSONRPCNotification(method: method, params: params)
                self = .notification(notification)
            }
        } else if let error {
            let response = JSONRPCErrorResponse(id: id, error: error)
            self = .error(response)
        } else if let id {
            let result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
            let response = JSONRPCResponse(id: id, result: result)
            self = .response(response)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown JSON-RPC shape"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .request(let request):
            try container.encodeIfPresent(request.jsonrpc, forKey: .jsonrpc)
            try container.encode(request.id, forKey: .id)
            try container.encode(request.method, forKey: .method)
            try container.encodeIfPresent(request.params, forKey: .params)
        case .notification(let notification):
            try container.encodeIfPresent(notification.jsonrpc, forKey: .jsonrpc)
            try container.encode(notification.method, forKey: .method)
            try container.encodeIfPresent(notification.params, forKey: .params)
        case .response(let response):
            try container.encodeIfPresent(response.jsonrpc, forKey: .jsonrpc)
            try container.encode(response.id, forKey: .id)
            try container.encodeIfPresent(response.result, forKey: .result)
        case .error(let error):
            try container.encodeIfPresent(error.jsonrpc, forKey: .jsonrpc)
            try container.encodeIfPresent(error.id, forKey: .id)
            try container.encode(error.error, forKey: .error)
        }
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
        case result
        case error
    }
}

public typealias AppServerMessage = JSONRPCMessage