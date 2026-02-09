import Foundation
import ACP

public struct ACPPermissionRequest: Equatable, Sendable {
    public let sessionId: String?
    public let toolCallId: String?
    public let toolCallTitle: String
    public let toolCallKind: String?
    public let options: [ACPPermissionOption]
}

public struct ACPPermissionOption: Equatable, Sendable {
    public let optionId: String
    public let name: String
    public let kind: ACPPermissionOptionKind
}

public enum ACPPermissionOptionKind: String, Equatable, Sendable {
    case allowOnce = "allow_once"
    case allowAlways = "allow_always"
    case rejectOnce = "reject_once"
    case rejectAlways = "reject_always"
    case unknown

    public init(from string: String) {
        // Map alternate server spellings to our canonical kinds
        switch string {
        case "proceed_once":
            self = .allowOnce
        case "proceed_always":
            self = .allowAlways
        case "cancel":
            self = .rejectOnce
        default:
            self = ACPPermissionOptionKind(rawValue: string) ?? .unknown
        }
    }
}

public enum ACPPermissionRequestParser {
    public static func parse(params: ACP.Value?) -> ACPPermissionRequest? {
        guard let paramsObject = params?.objectValue else { return nil }

        let sessionId = paramsObject["sessionId"]?.stringValue
        let toolCall = paramsObject["toolCall"]?.objectValue
        let toolCallId = toolCall?["toolCallId"]?.stringValue
        let toolCallTitle = toolCall?["title"]?.stringValue ?? "Unknown operation"
        let toolCallKind = toolCall?["kind"]?.stringValue

        var options: [ACPPermissionOption] = []
        if case let .array(optionsArray)? = paramsObject["options"] {
            for optionValue in optionsArray {
                guard let option = optionValue.objectValue,
                      let optionId = option["optionId"]?.stringValue,
                      let name = option["name"]?.stringValue else {
                    continue
                }
                let kindString = option["kind"]?.stringValue ?? "unknown"
                let kind = ACPPermissionOptionKind(from: kindString)
                options.append(ACPPermissionOption(optionId: optionId, name: name, kind: kind))
            }
        }

        return ACPPermissionRequest(
            sessionId: sessionId,
            toolCallId: toolCallId,
            toolCallTitle: toolCallTitle,
            toolCallKind: toolCallKind,
            options: options
        )
    }
}