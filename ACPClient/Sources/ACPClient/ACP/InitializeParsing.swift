import Foundation
import ACP

public enum ACPConnectedProtocol: String, Equatable, Sendable {
    case acp
    case codexAppServer
}

public struct ACPAuthMethod: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String?) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct ACPInitializeResult: Equatable, Sendable {
    public let connectedProtocol: ACPConnectedProtocol?
    public let agentInfo: AgentProfile?
    public let authMethods: [ACPAuthMethod]
    public let currentModeId: String?
    public let userAgent: String?
    public let promptCapabilitiesDeclared: Bool
}

public enum ACPInitializeParser {
    public static func parse(result: ACP.Value?) -> ACPInitializeResult? {
        guard let resultObject = result?.objectValue else { return nil }
        return parse(result: resultObject)
    }

    public static func parse(result: [String: ACP.Value]) -> ACPInitializeResult {
        let hasAcpMarkers = result["protocolVersion"] != nil
            || result["agentCapabilities"] != nil
            || result["agentInfo"] != nil
            || result["agent"] != nil

        let userAgent = result["userAgent"]?.stringValue
        let connectedProtocol: ACPConnectedProtocol? = hasAcpMarkers ? .acp : (userAgent != nil ? .codexAppServer : nil)

        let authMethods: [ACPAuthMethod]
        if case let .array(items)? = result["authMethods"] {
            authMethods = items.compactMap { item in
                guard let obj = item.objectValue,
                      let id = obj["id"]?.stringValue,
                      let name = obj["name"]?.stringValue else {
                    return nil
                }
                let description = obj["description"]?.stringValue
                return ACPAuthMethod(id: id, name: name, description: description)
            }
        } else {
            authMethods = []
        }

        let currentModeId = result["modes"]?.objectValue?["currentModeId"]?.stringValue

        let capabilitiesObj = result["agentCapabilities"]?.objectValue
            ?? result["capabilities"]?.objectValue
        let promptCapabilitiesDeclared = capabilitiesObj?["promptCapabilities"]?.objectValue != nil

        let agentInfo: AgentProfile?
        switch connectedProtocol {
        case .codexAppServer:
            if let userAgent {
                agentInfo = makeCodexAgentInfo(userAgent: userAgent)
            } else {
                agentInfo = nil
            }
        case .acp:
            agentInfo = AgentProfile.parse(from: result)
        case .none:
            agentInfo = nil
        }

        return ACPInitializeResult(
            connectedProtocol: connectedProtocol,
            agentInfo: agentInfo,
            authMethods: authMethods,
            currentModeId: currentModeId,
            userAgent: userAgent,
            promptCapabilitiesDeclared: promptCapabilitiesDeclared
        )
    }

    private static func makeCodexAgentInfo(userAgent: String) -> AgentProfile {
        var capabilities = AgentCapabilityState()
        capabilities.loadSession = false
        capabilities.resumeSession = false
        capabilities.listSessions = true
        capabilities.sessionListRequiresCwd = false
        capabilities.promptCapabilities = PromptCapabilityState()

        return AgentProfile(
            id: nil,
            name: "codex-app-server",
            title: "Codex app-server",
            version: nil,
            description: userAgent,
            modes: [],
            capabilities: capabilities,
            verifications: []
        )
    }
}