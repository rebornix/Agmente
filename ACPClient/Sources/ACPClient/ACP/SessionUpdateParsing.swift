import Foundation
import ACP

public enum ACPSessionUpdateParser {
    public static func parse(params: ACP.Value?) -> (sessionId: String?, update: [String: ACP.Value], kind: String?) {
        guard let object = params?.objectValue else { return (nil, [:], nil) }
        let session = object["sessionId"]?.stringValue
        let update = object["update"]?.objectValue ?? object["sessionUpdate"]?.objectValue ?? [:]
        let kind = update["sessionUpdate"]?.stringValue ?? update["type"]?.stringValue
        return (session, update, kind)
    }

    public static func summarize(
        params: ACP.Value?,
        fallbackCompact: (([String: ACP.Value]) -> String)? = nil
    ) -> String {
        guard let object = params?.objectValue else { return "session/update" }
        let session = object["sessionId"]?.stringValue ?? "unknown"
        let update = object["update"]?.objectValue ?? object["sessionUpdate"]?.objectValue ?? [:]
        let kind = update["sessionUpdate"]?.stringValue ?? update["type"]?.stringValue

        if let kind {
            switch kind {
            case "plan":
                let title = update["title"]?.stringValue ?? "Plan"
                return "session/update [\(session)] plan: \(title)"
            case "agent_message_chunk":
                let text = extractText(from: update)
                return "session/update [\(session)] message: \(text)"
            case "tool_call":
                let title = update["title"]?.stringValue ?? update["name"]?.stringValue ?? "tool"
                let toolKind = update["kind"]?.stringValue
                if let toolKind = toolKind {
                    return "session/update [\(session)] tool_call [\(toolKind)] \(title)"
                }
                return "session/update [\(session)] tool_call \(title)"
            case "tool_call_update":
                let status = update["status"]?.stringValue ?? "unknown"
                return "session/update [\(session)] tool_call_update: \(status)"
            case "available_commands_update":
                return "session/update [\(session)] available commands updated"
            case "current_mode_update":
                if let mode = update["modeId"]?.stringValue {
                    return "session/update [\(session)] mode -> \(mode)"
                }
            default:
                break
            }
        }

        let compact = fallbackCompact?(update) ?? compactJSON(update)
        return "session/update [\(session)] \(compact)"
    }

    /// Extract human-readable text from a session/update payload.
    public static func extractText(from update: [String: ACP.Value]) -> String {
        if let text = update["content"]?.stringValue {
            return text
        }
        if let text = update["content"]?.objectValue?["text"]?.stringValue {
            return text
        }
        if case let .array(items)? = update["content"] {
            for element in items {
                if let text = element.objectValue?["content"]?.objectValue?["text"]?.stringValue {
                    return text
                }
                if let text = element.objectValue?["text"]?.stringValue {
                    return text
                }
            }
        }
        return ""
    }

    public static func userMessageText(from update: [String: ACP.Value]) -> String {
        extractText(from: update)
    }

    public static func toolCallTitle(from update: [String: ACP.Value], fallback: String = "Unknown tool") -> String {
        let title = update["title"]?.stringValue
            ?? update["name"]?.stringValue
            ?? update["toolName"]?.stringValue
        return title?.isEmpty == false ? title! : fallback
    }

    public static func toolCallId(from update: [String: ACP.Value]) -> String? {
        update["toolCallId"]?.stringValue
    }

    public static func toolCallKind(from update: [String: ACP.Value]) -> String? {
        update["kind"]?.stringValue
    }

    public static func toolCallStatus(from update: [String: ACP.Value]) -> String? {
        update["status"]?.stringValue
    }

    public static func toolCallUpdatedTitle(from update: [String: ACP.Value]) -> String? {
        let title = update["title"]?.stringValue
            ?? update["name"]?.stringValue
            ?? update["toolName"]?.stringValue
        return title?.isEmpty == true ? nil : title
    }

    public static func toolCallUpdatedKind(from update: [String: ACP.Value]) -> String? {
        let kind = update["kind"]?.stringValue
        return kind?.isEmpty == true ? nil : kind
    }

    public static func toolCallOutput(from update: [String: ACP.Value]) -> String? {
        let text = update["rawOutput"]?.stringValue ?? extractText(from: update)
        return text.isEmpty ? nil : text
    }

    private static func compactJSON(_ object: [String: ACP.Value]) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(ACP.Value.object(object)),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}