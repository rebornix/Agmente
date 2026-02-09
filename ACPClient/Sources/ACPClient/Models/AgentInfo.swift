import Foundation
import ACP

// MARK: - Agent Info

/// Parsed agent information from the initialize response.
public struct AgentProfile: Equatable, Sendable {
    public let id: String?
    public let name: String
    public let title: String?
    public let version: String?
    public let description: String?
    public let modes: [AgentModeOption]
    public var capabilities: AgentCapabilityState
    public let verifications: [AgentCapabilityVerification]

    public init(
        id: String?,
        name: String,
        title: String? = nil,
        version: String? = nil,
        description: String? = nil,
        modes: [AgentModeOption] = [],
        capabilities: AgentCapabilityState = AgentCapabilityState(),
        verifications: [AgentCapabilityVerification] = []
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.version = version
        self.description = description
        self.modes = modes
        self.capabilities = capabilities
        self.verifications = verifications
    }

    /// Display name for the agent (prefers title over name).
    public var displayName: String {
        title ?? name
    }

    /// Full display string including version.
    public var displayNameWithVersion: String {
        if let version, !version.isEmpty {
            return "\(displayName) v\(version)"
        }
        return displayName
    }

    /// Whether this agent requires JSON without escaped forward slashes (e.g. `session/list` vs `session\\/list`).
    ///
    /// `codex-acp` currently rejects escaped slashes due to borrowed-string deserialization on the server side.
    public var requiresUnescapedSlashesInJSONRPC: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex-acp"
    }
}

/// An agent mode (e.g., "plan", "default", "auto-edit", "yolo").
public struct AgentModeOption: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// A slash command advertised by the agent.
public struct SessionCommand: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let inputHint: String?

    public init(id: String, name: String, description: String, inputHint: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.inputHint = inputHint
    }
}

/// Parsed agent capabilities from the initialize response.
public struct AgentCapabilityState: Equatable, Sendable {
    /// Whether the agent supports session/load.
    public var loadSession: Bool

    /// Whether the agent supports session/resume.
    public var resumeSession: Bool

    /// Whether the agent supports session/list.
    public var listSessions: Bool

    /// Whether session/list requires a working directory parameter.
    /// If true, we must call session/list once per used working directory.
    public var sessionListRequiresCwd: Bool

    /// Prompt capabilities (image, audio, embedded context).
    public var promptCapabilities: PromptCapabilityState

    public init(
        loadSession: Bool = false,
        resumeSession: Bool = false,
        listSessions: Bool = true,
        sessionListRequiresCwd: Bool = false,
        promptCapabilities: PromptCapabilityState = PromptCapabilityState()
    ) {
        self.loadSession = loadSession
        self.resumeSession = resumeSession
        self.listSessions = listSessions
        self.sessionListRequiresCwd = sessionListRequiresCwd
        self.promptCapabilities = promptCapabilities
    }
}

/// Prompt capabilities extracted from agentCapabilities.promptCapabilities.
public struct PromptCapabilityState: Equatable, Sendable {
    public var audio: Bool
    public var image: Bool
    public var embeddedContext: Bool

    public init(audio: Bool = false, image: Bool = false, embeddedContext: Bool = false) {
        self.audio = audio
        self.image = image
        self.embeddedContext = embeddedContext
    }
}

// MARK: - Agent Capability Verification

public enum AgentCapabilityOutcome: String, Sendable {
    case verified
    case warning
}

/// Represents a known verification or warning for an agent capability.
public struct AgentCapabilityVerification: Equatable, Sendable {
    public let feature: String
    public let outcome: AgentCapabilityOutcome
    public let details: String
    public let versionRequirement: VersionRequirement

    public init(feature: String, outcome: AgentCapabilityOutcome, details: String, versionRequirement: VersionRequirement) {
        self.feature = feature
        self.outcome = outcome
        self.details = details
        self.versionRequirement = versionRequirement
    }

    /// Whether this verification applies to the given version string.
    public func applies(to version: String?) -> Bool {
        versionRequirement.matches(versionString: version)
    }
}

/// Minimal semantic version representation for gating agent verifications.
public struct SemanticVersion: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ string: String) {
        let parts = string.split(separator: ".").map { Int($0) ?? 0 }
        guard !parts.isEmpty else { return nil }
        self.major = parts.count > 0 ? parts[0] : 0
        self.minor = parts.count > 1 ? parts[1] : 0
        self.patch = parts.count > 2 ? parts[2] : 0
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// Version bounds for applying capability verifications.
public struct VersionRequirement: Equatable, Sendable {
    public let min: SemanticVersion?
    public let max: SemanticVersion?

    public init(min: SemanticVersion?, max: SemanticVersion?) {
        self.min = min
        self.max = max
    }

    public static let any = VersionRequirement(min: nil, max: nil)

    public func matches(versionString: String?) -> Bool {
        guard let versionString, let version = SemanticVersion(versionString) else {
            // If we cannot parse the version, only apply if bounds are unspecified.
            return min == nil && max == nil
        }

        if let min, version < min { return false }
        if let max, version > max { return false }
        return true
    }
}

// MARK: - Agent Behavior Rules

/// Static rules for agent-specific behavior based on agent name/id.
public enum AgentBehaviorRules {
    /// Apply agent-specific capability overrides based on known agent behavior.
    /// Call this after parsing base capabilities from the initialize response.
    public static func applyRules(for agentName: String, capabilities: inout AgentCapabilityState) {
        let normalizedName = agentName.lowercased()

        switch normalizedName {
        case "qwen-code":
            // Qwen Code requires working directory for session/list
            capabilities.sessionListRequiresCwd = true

        default:
            break
        }
    }

    /// Known capability verifications and warnings for specific agents.
    public static func verifications(for agentName: String, version: String?) -> [AgentCapabilityVerification] {
        let normalizedName = agentName.lowercased()
        var results: [AgentCapabilityVerification] = []

        if normalizedName == "qwen" || normalizedName.hasPrefix("qwen-") {
            let requirement = VersionRequirement(min: nil, max: SemanticVersion("3.0.0"))
            let warning = AgentCapabilityVerification(
                feature: "promptCapabilities.image",
                outcome: .warning,
                details: "Agent advertises image prompts but current builds reject image content blocks; treat image support as unreliable.",
                versionRequirement: requirement
            )
            if warning.applies(to: version) {
                results.append(warning)
            }
        }

        if normalizedName.contains("claude") {
            // session/resume added in v0.12.3
            let resumeReq = VersionRequirement(min: nil, max: SemanticVersion("0.12.2"))
            let resumeWarning = AgentCapabilityVerification(
                feature: "sessionCapabilities.resume",
                outcome: .warning,
                details: "Session resume requires claude-code-acp v0.12.3 or later.",
                versionRequirement: resumeReq
            )
            if resumeWarning.applies(to: version) {
                results.append(resumeWarning)
            }

            // session/fork added in v0.12.4
            let forkReq = VersionRequirement(min: nil, max: SemanticVersion("0.12.3"))
            let forkWarning = AgentCapabilityVerification(
                feature: "sessionCapabilities.fork",
                outcome: .warning,
                details: "Session forking requires claude-code-acp v0.12.4 or later.",
                versionRequirement: forkReq
            )
            if forkWarning.applies(to: version) {
                results.append(forkWarning)
            }
        }

        return results
    }

    /// Check if an agent is known to require working directory for session listing.
    public static func requiresCwdForSessionList(agentName: String?) -> Bool {
        guard let name = agentName?.lowercased() else { return false }
        return name == "qwen-code"
    }
}

// MARK: - Parsing

public extension AgentProfile {
    /// Parse AgentProfile from an initialize response result.
    /// - Parameter result: The "result" object from the initialize response.
    static func parse(from result: [String: ACP.Value]) -> AgentProfile {
        // Agent info can be under "agentInfo" or "agent"
        let agentObj = result["agentInfo"]?.objectValue
            ?? result["agent"]?.objectValue
            ?? [:]

        let name = agentObj["name"]?.stringValue ?? "Agent"
        let id = agentObj["id"]?.stringValue
        let title = agentObj["title"]?.stringValue
        let version = agentObj["version"]?.stringValue
        let description = agentObj["description"]?.stringValue

        // Parse modes
        var modes: [AgentModeOption] = []
        if let modesObj = result["modes"]?.objectValue,
           case let .array(availableModes)? = modesObj["availableModes"] {
            modes = availableModes.compactMap { modeValue -> AgentModeOption? in
                guard let modeObj = modeValue.objectValue,
                      let modeId = modeObj["id"]?.stringValue,
                      let modeName = modeObj["name"]?.stringValue else { return nil }
                return AgentModeOption(
                    id: modeId,
                    name: modeName,
                    description: modeObj["description"]?.stringValue
                )
            }
        }

        // Parse capabilities
        var capabilities = AgentCapabilityState()
        let capabilitiesObj = result["agentCapabilities"]?.objectValue
            ?? result["capabilities"]?.objectValue
            ?? [:]

        if let loadSession = capabilitiesObj["loadSession"]?.boolValue {
            capabilities.loadSession = loadSession
        }

        if let sessionCaps = capabilitiesObj["sessionCapabilities"]?.objectValue {
            // session/resume capability is represented by a nested object:
            // { "sessionCapabilities": { "resume": {} } }
            if sessionCaps["resume"] != nil {
                capabilities.resumeSession = true
            }
        }

        if let listSessions = capabilitiesObj["listSessions"]?.boolValue {
            capabilities.listSessions = listSessions
        }

        if let sessionListRequiresCwd = capabilitiesObj["sessionListRequiresCwd"]?.boolValue {
            capabilities.sessionListRequiresCwd = sessionListRequiresCwd
        }

        // Parse prompt capabilities
        if let promptCaps = capabilitiesObj["promptCapabilities"]?.objectValue {
            capabilities.promptCapabilities.audio = promptCaps["audio"]?.boolValue ?? false
            capabilities.promptCapabilities.image = promptCaps["image"]?.boolValue ?? false
            capabilities.promptCapabilities.embeddedContext = promptCaps["embeddedContext"]?.boolValue ?? false
        }

        // Apply agent-specific rules
        AgentBehaviorRules.applyRules(for: name, capabilities: &capabilities)

        let verifications = AgentBehaviorRules.verifications(for: name, version: version)

        return AgentProfile(
            id: id,
            name: name,
            title: title,
            version: version,
            description: description,
            modes: modes,
            capabilities: capabilities,
            verifications: verifications
        )
    }

    /// Parse AgentProfile from an initialize response result.
    /// - Parameter result: The "result" object from the initialize response.
    static func parse(from result: [String: Any]?) -> AgentProfile? {
        guard let result = result else { return nil }

        // Agent info can be under "agentInfo" or "agent"
        let agentObj = (result["agentInfo"] as? [String: Any])
            ?? (result["agent"] as? [String: Any])
            ?? [:]

        let name = (agentObj["name"] as? String) ?? "Agent"
        let id = agentObj["id"] as? String
        let title = agentObj["title"] as? String
        let version = agentObj["version"] as? String
        let description = agentObj["description"] as? String

        // Parse modes
        var modes: [AgentModeOption] = []
        if let modesObj = result["modes"] as? [String: Any],
           let availableModes = modesObj["availableModes"] as? [[String: Any]] {
            modes = availableModes.compactMap { modeObj in
                guard let modeId = modeObj["id"] as? String,
                      let modeName = modeObj["name"] as? String else { return nil }
                return AgentModeOption(
                    id: modeId,
                    name: modeName,
                    description: modeObj["description"] as? String
                )
            }
        }

        // Parse capabilities
        var capabilities = AgentCapabilityState()
        let capabilitiesObj = (result["agentCapabilities"] as? [String: Any])
            ?? (result["capabilities"] as? [String: Any])
            ?? [:]

        if let loadSession = capabilitiesObj["loadSession"] as? Bool {
            capabilities.loadSession = loadSession
        }

        if let sessionCaps = capabilitiesObj["sessionCapabilities"] as? [String: Any] {
            // session/resume capability is represented by a nested object:
            // { "sessionCapabilities": { "resume": {} } }
            if sessionCaps["resume"] != nil {
                capabilities.resumeSession = true
            }
        }

        if let listSessions = capabilitiesObj["listSessions"] as? Bool {
            capabilities.listSessions = listSessions
        }

        if let sessionListRequiresCwd = capabilitiesObj["sessionListRequiresCwd"] as? Bool {
            capabilities.sessionListRequiresCwd = sessionListRequiresCwd
        }

        // Parse prompt capabilities
        if let promptCaps = capabilitiesObj["promptCapabilities"] as? [String: Any] {
            capabilities.promptCapabilities.audio = (promptCaps["audio"] as? Bool) ?? false
            capabilities.promptCapabilities.image = (promptCaps["image"] as? Bool) ?? false
            capabilities.promptCapabilities.embeddedContext = (promptCaps["embeddedContext"] as? Bool) ?? false
        }

        // Apply agent-specific rules
        AgentBehaviorRules.applyRules(for: name, capabilities: &capabilities)

        let verifications = AgentBehaviorRules.verifications(for: name, version: version)

        return AgentProfile(
            id: id,
            name: name,
            title: title,
            version: version,
            description: description,
            modes: modes,
            capabilities: capabilities,
            verifications: verifications
        )
    }
}

public extension SessionCommand {
    static func parse(from update: [String: ACP.Value]) -> [SessionCommand] {
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