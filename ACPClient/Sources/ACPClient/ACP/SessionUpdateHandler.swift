import Foundation
import ACP

// MARK: - Session Update Events

/// High-level events emitted when interpreting session/update notifications.
public enum ACPSessionUpdateEvent: Equatable, Sendable {
    /// Agent is streaming thought/reasoning content.
    case agentThought(text: String)
    
    /// User message chunk (typically echo of submitted prompt during replay).
    case userMessage(text: String)
    
    /// Agent is streaming response text.
    case agentMessage(text: String)
    
    /// A tool call has been initiated.
    case toolCall(ACPToolCallInfo)
    
    /// An existing tool call has been updated (status change, output, etc.).
    case toolCallUpdate(ACPToolCallUpdate)
    
    /// The agent's current mode has changed.
    case modeChange(modeId: String)
    
    /// Available slash commands have been updated.
    case availableCommandsUpdate(commands: [SessionCommand])
}

// MARK: - Tool Call Models

/// Information about a tool call from a session update.
public struct ACPToolCallInfo: Equatable, Sendable {
    public let toolCallId: String?
    public let title: String
    public let kind: String?
    public let status: String
    
    public init(toolCallId: String?, title: String, kind: String?, status: String) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
    }
}

/// Update to an existing tool call.
public struct ACPToolCallUpdate: Equatable, Sendable {
    public let toolCallId: String?
    public let status: String?
    public let title: String?
    public let kind: String?
    public let output: String?
    
    public init(toolCallId: String?, status: String?, title: String?, kind: String?, output: String?) {
        self.toolCallId = toolCallId
        self.status = status
        self.title = title
        self.kind = kind
        self.output = output
    }
}

// MARK: - Session Update Handler

/// Interprets raw session/update notification payloads and emits typed events.
///
/// Usage:
/// ```swift
/// let handler = ACPSessionUpdateHandler()
/// let events = handler.handle(params: notification.params)
/// for event in events {
///     switch event {
///     case .agentMessage(let text): // append to chat
///     case .toolCall(let info): // show tool call UI
///     // ...
///     }
/// }
/// ```
public final class ACPSessionUpdateHandler: Sendable {
    public init() {}
    
    /// Interprets a session/update notification and returns typed events.
    /// - Parameters:
    ///   - params: The `params` field from the session/update notification.
    ///   - activeSessionId: If provided, events for other sessions are filtered out.
    /// - Returns: Array of typed events. May be empty if the update is not relevant.
    public func handle(params: ACP.Value?, activeSessionId: String? = nil) -> [ACPSessionUpdateEvent] {
        let parsed = ACPSessionUpdateParser.parse(params: params)
        
        // Filter by session if specified
        if let activeSessionId, let sessionId = parsed.sessionId, sessionId != activeSessionId {
            return []
        }
        
        guard let kind = parsed.kind else {
            // Unknown update type - try to extract text as fallback
            let text = ACPSessionUpdateParser.extractText(from: parsed.update)
            if !text.isEmpty {
                return [.agentMessage(text: text)]
            }
            return []
        }
        
        return interpretUpdate(kind: kind, update: parsed.update)
    }
    
    /// Interprets a parsed update by kind.
    private func interpretUpdate(kind: String, update: [String: ACP.Value]) -> [ACPSessionUpdateEvent] {
        switch kind {
        case "agent_thought_chunk":
            let text = ACPSessionUpdateParser.extractText(from: update)
            guard !text.isEmpty else { return [] }
            return [.agentThought(text: text)]
            
        case "user_message_chunk":
            let text = ACPSessionUpdateParser.userMessageText(from: update)
            guard !text.isEmpty else { return [] }
            return [.userMessage(text: text)]
            
        case "agent_message_chunk":
            let text = ACPSessionUpdateParser.extractText(from: update)
            guard !text.isEmpty else { return [] }
            return [.agentMessage(text: text)]
            
        case "tool_call":
            let info = parseToolCallInfo(from: update)
            return [.toolCall(info)]
            
        case "tool_call_update":
            let updateInfo = parseToolCallUpdate(from: update)
            return [.toolCallUpdate(updateInfo)]
            
        case "current_mode_update":
            if let modeId = update["modeId"]?.stringValue {
                return [.modeChange(modeId: modeId)]
            }
            return []
            
        case "available_commands_update":
            let commands = parseAvailableCommands(from: update)
            return [.availableCommandsUpdate(commands: commands)]
            
        default:
            // Unknown kind - try to extract text as fallback
            let text = ACPSessionUpdateParser.extractText(from: update)
            if !text.isEmpty {
                return [.agentMessage(text: text)]
            }
            return []
        }
    }
    
    // MARK: - Parsing Helpers
    
    private func parseToolCallInfo(from update: [String: ACP.Value]) -> ACPToolCallInfo {
        let title = ACPSessionUpdateParser.toolCallTitle(from: update)
        let kind = ACPSessionUpdateParser.toolCallKind(from: update)
        let toolCallId = ACPSessionUpdateParser.toolCallId(from: update)
        let status = ACPSessionUpdateParser.toolCallStatus(from: update) ?? "pending"
        
        return ACPToolCallInfo(
            toolCallId: toolCallId,
            title: title,
            kind: kind,
            status: status
        )
    }
    
    private func parseToolCallUpdate(from update: [String: ACP.Value]) -> ACPToolCallUpdate {
        let toolCallId = ACPSessionUpdateParser.toolCallId(from: update)
        let status = ACPSessionUpdateParser.toolCallStatus(from: update)
        let title = ACPSessionUpdateParser.toolCallUpdatedTitle(from: update)
        let kind = ACPSessionUpdateParser.toolCallUpdatedKind(from: update)
        let output = ACPSessionUpdateParser.toolCallOutput(from: update)
        
        return ACPToolCallUpdate(
            toolCallId: toolCallId,
            status: status,
            title: title,
            kind: kind,
            output: output
        )
    }
    
    private func parseAvailableCommands(from update: [String: ACP.Value]) -> [SessionCommand] {
        guard case let .array(commandValues)? = update["availableCommands"] else { return [] }
        
        return commandValues.compactMap { value in
            guard let commandObj = value.objectValue,
                  let name = commandObj["name"]?.stringValue,
                  let description = commandObj["description"]?.stringValue else { return nil }
            let inputHint = commandObj["input"]?.objectValue?["hint"]?.stringValue
            
            return SessionCommand(id: name, name: name, description: description, inputHint: inputHint)
        }
    }
}

// MARK: - Convenience Extensions

public extension ACPSessionUpdateHandler {
    /// Extract the session ID from a session/update notification.
    static func sessionId(from params: ACP.Value?) -> String? {
        ACPSessionUpdateParser.parse(params: params).sessionId
    }
}