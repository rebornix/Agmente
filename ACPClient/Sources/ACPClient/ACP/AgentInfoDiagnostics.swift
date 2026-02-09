import Foundation

public enum AgentInfoDiagnostics {
    /// Returns a human-readable summary of the agent's prompt capabilities.
    public static func promptCapabilitiesSummary(declared: Bool, capabilities: AgentCapabilityState) -> String {
        if declared {
            return "Agent promptCapabilities: audio=\(capabilities.promptCapabilities.audio), image=\(capabilities.promptCapabilities.image), embeddedContext=\(capabilities.promptCapabilities.embeddedContext)"
        } else {
            return "Agent has no promptCapabilities declared"
        }
    }

    /// Returns a human-readable summary of core agent capabilities commonly surfaced in logs.
    public static func capabilitySummary(for agentInfo: AgentProfile) -> String {
        let caps = agentInfo.capabilities
        return "Agent: \(agentInfo.displayNameWithVersion), loadSession: \(caps.loadSession), resumeSession: \(caps.resumeSession), sessionListRequiresCwd: \(caps.sessionListRequiresCwd)"
    }
}