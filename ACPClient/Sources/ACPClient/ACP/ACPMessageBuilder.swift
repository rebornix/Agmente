import ACP
import Foundation

public enum ACPMessageBuilder {
    public static func initializedNotification() -> ACPWireMessage {
        .notification(ACP.AnyMessage(method: InitializedNotification.name, params: .null))
    }

    public static func permissionResponseSelected(requestId: ACP.ID, optionId: String) -> ACPWireMessage {
        let result: ACP.Value = .object([
            "outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string(optionId),
            ]),
        ])
        return .response(ACP.AnyResponse(id: requestId, result: result))
    }

    public static func permissionResponseCancelled(requestId: ACP.ID) -> ACPWireMessage {
        let result: ACP.Value = .object([
            "outcome": .object([
                "outcome": .string("cancelled"),
            ]),
        ])
        return .response(ACP.AnyResponse(id: requestId, result: result))
    }

    public static func errorResponse(requestId: ACP.ID, code: Int, message: String) -> ACPWireMessage {
        let error: ACPError
        switch code {
        case ACPError.Code.parseError:
            error = .parseError(message)
        case ACPError.Code.invalidRequest:
            error = .invalidRequest(message)
        case ACPError.Code.methodNotFound:
            error = .methodNotFound(message)
        case ACPError.Code.invalidParams:
            error = .invalidParams(message)
        case ACPError.Code.internalError:
            error = .internalError(message)
        default:
            error = .serverError(code: code, message: message)
        }
        return .response(ACP.AnyResponse(id: requestId, error: error))
    }
}