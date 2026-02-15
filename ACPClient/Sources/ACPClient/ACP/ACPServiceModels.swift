import Foundation
import ACP

public struct ACPInitializationPayload: Sendable {
    public var protocolVersion: Int
    public var clientName: String
    public var clientTitle: String?
    public var clientVersion: String
    public var clientCapabilities: [String: ACP.Value]
    /// Codex app-server capabilities (sent as "capabilities" in the initialize params).
    /// Separate from clientCapabilities which is ACP-specific.
    public var capabilities: [String: ACP.Value]
    public var options: [String: ACP.Value]

    public init(
        protocolVersion: Int = 1,
        clientName: String,
        clientVersion: String,
        clientTitle: String? = nil,
        clientCapabilities: [String: ACP.Value] = [:],
        capabilities: [String: ACP.Value] = [:],
        options: [String: ACP.Value] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.clientName = clientName
        self.clientTitle = clientTitle
        self.clientVersion = clientVersion
        self.clientCapabilities = clientCapabilities
        self.capabilities = capabilities
        self.options = options
    }

    func params() -> ACP.Value {
        var clientInfo: [String: ACP.Value?] = [
            "name": .string(clientName),
            "version": .string(clientVersion)
        ]
        clientInfo["title"] = clientTitle.map(ACP.Value.string)

        var object: [String: ACP.Value?] = [
            "protocolVersion": .number(Double(protocolVersion)),
            "clientInfo": .object(clientInfo.compactMapValues { $0 }),
            "clientCapabilities": .object(clientCapabilities)
        ]
        if !capabilities.isEmpty {
            object["capabilities"] = .object(capabilities)
        }
        if !options.isEmpty {
            object["options"] = .object(options)
        }
        return .object(object.compactMapValues { $0 })
    }
}

public struct ACPSessionCreatePayload: Sendable {
    public var workingDirectory: String
    public var mcpServers: [ACP.Value]
    public var agent: String?
    public var metadata: [String: ACP.Value]

    public init(
        workingDirectory: String,
        mcpServers: [ACP.Value] = [],
        agent: String? = nil,
        metadata: [String: ACP.Value] = [:]
    ) {
        self.workingDirectory = workingDirectory
        self.mcpServers = mcpServers
        self.agent = agent
        self.metadata = metadata
    }

    func params() -> ACP.Value {
        var object: [String: ACP.Value?] = [
            "cwd": .string(workingDirectory),
            "mcpServers": .array(mcpServers)
        ]
        if let agent {
            object["agent"] = .string(agent)
        }
        if !metadata.isEmpty {
            object["metadata"] = .object(metadata)
        }
        return .object(object.compactMapValues { $0 })
    }
}

public struct ACPSessionLoadPayload: Sendable {
    public var sessionId: String
    public var workingDirectory: String
    public var mcpServers: [ACP.Value]

    public init(
        sessionId: String,
        workingDirectory: String,
        mcpServers: [ACP.Value] = []
    ) {
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.mcpServers = mcpServers
    }

    func params() -> ACP.Value {
        .object([
            "sessionId": .string(sessionId),
            "cwd": .string(workingDirectory),
            "mcpServers": .array(mcpServers)
        ])
    }
}

public struct ACPSessionResumePayload: Sendable {
    public var sessionId: String
    public var workingDirectory: String
    public var mcpServers: [ACP.Value]

    public init(
        sessionId: String,
        workingDirectory: String,
        mcpServers: [ACP.Value] = []
    ) {
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.mcpServers = mcpServers
    }

    func params() -> ACP.Value {
        .object([
            "sessionId": .string(sessionId),
            "cwd": .string(workingDirectory),
            "mcpServers": .array(mcpServers)
        ])
    }
}

public struct ACPSessionPromptPayload: Sendable {
    public var sessionId: String
    public var prompt: [ACP.Value]
    public var attachments: [String: ACP.Value]
    public var stream: Bool?

    public init(
        sessionId: String,
        prompt: [ACP.Value],
        attachments: [String: ACP.Value] = [:],
        stream: Bool? = nil
    ) {
        self.sessionId = sessionId
        self.prompt = prompt
        self.attachments = attachments
        self.stream = stream
    }

    func params() -> ACP.Value {
        var object: [String: ACP.Value?] = [
            "sessionId": .string(sessionId),
            "prompt": .array(prompt)
        ]
        if !attachments.isEmpty {
            object["attachments"] = .object(attachments)
        }
        if let stream {
            object["stream"] = .bool(stream)
        }
        return .object(object.compactMapValues { $0 })
    }
}

public struct ACPSessionCancelPayload: Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }

    func params() -> ACP.Value {
        .object(["sessionId": .string(sessionId)])
    }
}

public struct ACPSessionListPayload: Sendable {
    public var limit: Int?
    public var cursor: String?
    public var workingDirectory: String?

    public init(limit: Int? = nil, cursor: String? = nil, workingDirectory: String? = nil) {
        self.limit = limit
        self.cursor = cursor
        self.workingDirectory = workingDirectory
    }

    func params() -> ACP.Value {
        var object: [String: ACP.Value?] = [:]
        if let limit {
            object["limit"] = .number(Double(limit))
        }
        if let cursor {
            object["cursor"] = .string(cursor)
        }
        if let workingDirectory {
            object["cwd"] = .string(workingDirectory)
        }
        return .object(object.compactMapValues { $0 })
    }
}

public struct ACPSessionSetModePayload: Sendable {
    public var sessionId: String
    public var modeId: String

    public init(sessionId: String, modeId: String) {
        self.sessionId = sessionId
        self.modeId = modeId
    }

    func params() -> ACP.Value {
        .object([
            "sessionId": .string(sessionId),
            "modeId": .string(modeId)
        ])
    }
}