import ACP
import Foundation

public extension JSONRPCID {
    init(_ id: ACP.ID) {
        switch id {
        case .string(let value):
            self = .string(value)
        case .number(let value):
            self = .int(value)
        case .null:
            self = .int(0)
        }
    }

    var acpID: ACP.ID {
        switch self {
        case .string(let value):
            return .string(value)
        case .int(let value):
            return .number(value)
        }
    }
}

public extension JSONValue {
    init(_ value: ACP.Value) {
        switch value {
        case .null:
            self = .null
        case .bool(let value):
            self = .bool(value)
        case .int(let value):
            self = .number(Double(value))
        case .double(let value):
            self = .number(value)
        case .string(let value):
            self = .string(value)
        case .array(let values):
            self = .array(values.map(JSONValue.init))
        case .object(let object):
            self = .object(object.mapValues(JSONValue.init))
        }
    }

    var acpValue: ACP.Value {
        switch self {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .number(let value):
            if let intValue = Int(exactly: value) {
                return .int(intValue)
            }
            return .double(value)
        case .string(let value):
            return .string(value)
        case .array(let values):
            return .array(values.map { $0.acpValue })
        case .object(let object):
            return .object(object.mapValues { $0.acpValue })
        }
    }
}

public extension JSONRPCRequest {
    init(_ request: ACP.AnyRequest) {
        self.init(
            id: JSONRPCID(request.id),
            method: request.method,
            params: JSONValue(request.params)
        )
    }

    var acpRequest: ACP.AnyRequest {
        ACP.AnyRequest(id: id.acpID, method: method, params: params?.acpValue ?? .null)
    }
}

public extension JSONRPCNotification {
    init(_ notification: ACP.AnyMessage) {
        self.init(method: notification.method, params: JSONValue(notification.params))
    }

    var acpMessage: ACP.AnyMessage {
        ACP.AnyMessage(method: method, params: params?.acpValue ?? .null)
    }
}

public extension JSONRPCResponse {
    init?(_ response: ACP.AnyResponse) {
        guard response.id != .null else { return nil }
        self.init(
            id: JSONRPCID(response.id),
            result: response.resultValue.map(JSONValue.init)
        )
    }

    var acpResponse: ACP.AnyResponse {
        ACP.AnyResponse(id: id.acpID, result: result?.acpValue ?? .null)
    }
}

public extension JSONRPCErrorResponse {
    init(_ id: JSONRPCID?, error: ACPError) {
        self.init(id: id, error: .init(code: error.code, message: error.message))
    }
}

public extension JSONRPCMessage {
    init(_ message: ACPWireMessage) {
        switch message {
        case .request(let request):
            self = .request(JSONRPCRequest(request))
        case .notification(let notification):
            self = .notification(JSONRPCNotification(notification))
        case .response(let response):
            if let error = response.errorValue {
                let responseId = response.id == .null ? nil : JSONRPCID(response.id)
                self = .error(JSONRPCErrorResponse(responseId, error: error))
            } else if let jsonResponse = JSONRPCResponse(response) {
                self = .response(jsonResponse)
            } else {
                let error = JSONRPCErrorResponse.Error(
                    code: -32600,
                    message: "Invalid response id",
                    data: nil
                )
                self = .error(JSONRPCErrorResponse(id: nil, error: error))
            }
        }
    }

    var acpWireMessage: ACPWireMessage {
        switch self {
        case .request(let request):
            return .request(request.acpRequest)
        case .notification(let notification):
            return .notification(notification.acpMessage)
        case .response(let response):
            return .response(response.acpResponse)
        case .error(let errorResponse):
            let requestId = errorResponse.id?.acpID ?? .null
            let error: ACPError
            switch errorResponse.error.code {
            case ACPError.Code.parseError:
                error = .parseError(errorResponse.error.message)
            case ACPError.Code.invalidRequest:
                error = .invalidRequest(errorResponse.error.message)
            case ACPError.Code.methodNotFound:
                error = .methodNotFound(errorResponse.error.message)
            case ACPError.Code.invalidParams:
                error = .invalidParams(errorResponse.error.message)
            case ACPError.Code.internalError:
                error = .internalError(errorResponse.error.message)
            default:
                error = .serverError(code: errorResponse.error.code, message: errorResponse.error.message)
            }
            return .response(ACP.AnyResponse(id: requestId, error: error))
        }
    }
}