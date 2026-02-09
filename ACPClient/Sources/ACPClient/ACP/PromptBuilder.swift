import Foundation
import ACP

// MARK: - Prompt Content Types

/// A content block within a prompt (text, image, audio, or context).
public enum ACPPromptContent: Sendable, Equatable {
    case text(String)
    case image(mimeType: String, base64Data: String)
    case audio(mimeType: String, base64Data: String)
    case context(text: String, source: String?)
    
    /// Convert to JSON for the ACP protocol.
    public func toJSON() -> ACP.Value {
        switch self {
        case .text(let text):
            return .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        case .image(let mimeType, let base64Data):
            return .object([
                "type": .string("image"),
                "mimeType": .string(mimeType),
                "data": .string(base64Data)
            ])
        case .audio(let mimeType, let base64Data):
            return .object([
                "type": .string("audio"),
                "mimeType": .string(mimeType),
                "data": .string(base64Data)
            ])
        case .context(let text, let source):
            var obj: [String: ACP.Value] = [
                "type": .string("context"),
                "text": .string(text)
            ]
            if let source {
                obj["source"] = .string(source)
            }
            return .object(obj)
        }
    }
    
    /// Debug description for logging (truncates long data).
    public var debugDescription: String {
        switch self {
        case .text(let text):
            let preview = text.count > 50 ? String(text.prefix(50)) + "..." : text
            return "{type:\"text\", text:\"\(preview)\"}"
        case .image(let mimeType, let base64Data):
            return "{type:\"image\", mimeType:\"\(mimeType)\", data:\"<\(base64Data.count) chars>\"}"
        case .audio(let mimeType, let base64Data):
            return "{type:\"audio\", mimeType:\"\(mimeType)\", data:\"<\(base64Data.count) chars>\"}"
        case .context(let text, let source):
            let preview = text.count > 50 ? String(text.prefix(50)) + "..." : text
            let sourceStr = source.map { ", source:\"\($0)\"" } ?? ""
            return "{type:\"context\", text:\"\(preview)\"\(sourceStr)}"
        }
    }
}

// MARK: - Image Input (Platform-agnostic)

/// Image data ready for inclusion in a prompt.
/// This is a platform-agnostic representation; the app layer handles UIImage conversion.
public struct ACPImageInput: Sendable {
    public let mimeType: String
    public let base64Data: String
    
    public init(mimeType: String, base64Data: String) {
        self.mimeType = mimeType
        self.base64Data = base64Data
    }
}

// MARK: - Build Result

/// Result of building prompt content.
public struct ACPPromptBuildResult: Sendable {
    /// The prompt content blocks ready for sending.
    public let contents: [ACPPromptContent]
    
    /// Warnings generated during building (e.g., unsupported content types).
    public let warnings: [String]
    
    /// Whether the prompt is valid (has at least one content block).
    public var isValid: Bool {
        !contents.isEmpty
    }
    
    /// Convert contents to JSON array for the ACP protocol.
    public func toJSONArray() -> [ACP.Value] {
        contents.map { $0.toJSON() }
    }
    
    /// Debug summary of all content blocks.
    public var debugSummary: String {
        "[\(contents.map { $0.debugDescription }.joined(separator: ", "))]"
    }
}

// MARK: - Prompt Builder

/// Builds prompt content for the ACP protocol.
///
/// Handles text, images, audio, and context attachments while validating
/// against the agent's declared prompt capabilities.
public struct ACPPromptBuilder {
    
    /// Build prompt content from text and optional images.
    /// - Parameters:
    ///   - text: The text prompt (may be empty if images are provided).
    ///   - images: Optional image attachments.
    ///   - capabilities: The agent's prompt capabilities for validation.
    /// - Returns: A build result with content blocks and any warnings.
    public static func build(
        text: String,
        images: [ACPImageInput] = [],
        capabilities: PromptCapabilityState? = nil
    ) -> ACPPromptBuildResult {
        var contents: [ACPPromptContent] = []
        var warnings: [String] = []
        
        // Add text content if not empty
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            contents.append(.text(text))
        }
        
        // Add image content blocks
        for image in images {
            if let capabilities, !capabilities.image {
                warnings.append("Agent does not support image prompts; image will be sent anyway but may be ignored.")
            }
            contents.append(.image(mimeType: image.mimeType, base64Data: image.base64Data))
        }
        
        return ACPPromptBuildResult(contents: contents, warnings: warnings)
    }
    
    /// Build prompt content with full options including audio and context.
    /// - Parameters:
    ///   - text: The text prompt.
    ///   - images: Optional image attachments.
    ///   - audio: Optional audio attachments.
    ///   - contexts: Optional embedded context blocks.
    ///   - capabilities: The agent's prompt capabilities for validation.
    /// - Returns: A build result with content blocks and any warnings.
    public static func build(
        text: String,
        images: [ACPImageInput] = [],
        audio: [ACPAudioInput] = [],
        contexts: [ACPContextInput] = [],
        capabilities: PromptCapabilityState? = nil
    ) -> ACPPromptBuildResult {
        var contents: [ACPPromptContent] = []
        var warnings: [String] = []
        
        // Add text content if not empty
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            contents.append(.text(text))
        }
        
        // Add image content blocks
        for image in images {
            if let capabilities, !capabilities.image {
                warnings.append("Agent does not support image prompts; image will be sent anyway but may be ignored.")
            }
            contents.append(.image(mimeType: image.mimeType, base64Data: image.base64Data))
        }
        
        // Add audio content blocks
        for audioInput in audio {
            if let capabilities, !capabilities.audio {
                warnings.append("Agent does not support audio prompts; audio will be sent anyway but may be ignored.")
            }
            contents.append(.audio(mimeType: audioInput.mimeType, base64Data: audioInput.base64Data))
        }
        
        // Add context blocks
        for context in contexts {
            if let capabilities, !capabilities.embeddedContext {
                warnings.append("Agent does not support embedded context; context will be sent anyway but may be ignored.")
            }
            contents.append(.context(text: context.text, source: context.source))
        }
        
        return ACPPromptBuildResult(contents: contents, warnings: warnings)
    }
    
    /// Validate that at least some content will be sent.
    /// - Parameter result: The build result to validate.
    /// - Returns: An error message if validation fails, nil otherwise.
    public static func validate(_ result: ACPPromptBuildResult) -> String? {
        if result.contents.isEmpty {
            return "Cannot send empty prompt"
        }
        return nil
    }
}

// MARK: - Audio and Context Inputs

/// Audio data ready for inclusion in a prompt.
public struct ACPAudioInput: Sendable {
    public let mimeType: String
    public let base64Data: String
    
    public init(mimeType: String, base64Data: String) {
        self.mimeType = mimeType
        self.base64Data = base64Data
    }
}

/// Context data for inclusion in a prompt.
public struct ACPContextInput: Sendable {
    public let text: String
    public let source: String?
    
    public init(text: String, source: String? = nil) {
        self.text = text
        self.source = source
    }
}

// MARK: - Convenience Extensions

public extension ACPPromptBuildResult {
    /// Create an ACPSessionPromptPayload from this build result.
    /// - Parameter sessionId: The session ID to send the prompt to.
    /// - Returns: A payload ready for sending, or nil if the result is invalid.
    func makePayload(sessionId: String, attachments: [String: ACP.Value] = [:]) -> ACPSessionPromptPayload? {
        guard isValid else { return nil }
        return ACPSessionPromptPayload(
            sessionId: sessionId,
            prompt: toJSONArray(),
            attachments: attachments
        )
    }
}