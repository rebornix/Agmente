import Foundation
import ACP

// MARK: - Response Action Types

/// Actions that can result from dispatching an RPC response.
/// The view model applies these to update UI state.
public enum ACPResponseAction: Sendable, Equatable {
    /// A session was created or loaded; activate it.
    case sessionActivated(ACPSessionActivation)
    
    /// Mark a session as materialized on the server.
    case sessionMaterialized(sessionId: String)
    
    /// Session placeholder should be migrated to resolved ID.
    case sessionMigrated(from: String, to: String)
    
    /// Mode was changed via session/set_mode.
    case modeChanged(modeId: String)
    
    /// Initialize response was received.
    case initialized(ACPInitializeResult)
    
    /// Stop reason received (prompt completed).
    case stopReason(String)
    
    /// Session list received from server.
    case sessionListReceived(ACPSessionListResult)
    
    /// Session was loaded; finish streaming.
    case sessionLoadCompleted
    
    /// A capability was confirmed as supported.
    case capabilityConfirmed(ACPCapabilityKind)
    
    /// A capability was disabled (method not found).
    case capabilityDisabled(ACPCapabilityKind)
    
    /// An RPC error was received.
    case rpcError(ACPRPCErrorInfo)
}

/// Session activation details.
public struct ACPSessionActivation: Sendable, Equatable {
    public let sessionId: String
    public let cwd: String?
    public let modes: ACPModesInfo?
    
    public init(sessionId: String, cwd: String? = nil, modes: ACPModesInfo? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.modes = modes
    }
}

/// Session list result with parsed summaries.
public struct ACPSessionListResult: Sendable, Equatable {
    public let sessions: [SessionSummary]
    public let isMultiCwdFetch: Bool
    
    public init(sessions: [SessionSummary], isMultiCwdFetch: Bool = false) {
        self.sessions = sessions
        self.isMultiCwdFetch = isMultiCwdFetch
    }
}

/// Capability kinds that can be confirmed or disabled.
public enum ACPCapabilityKind: String, Sendable, Equatable {
    case listSessions
    case loadSession
    case resumeSession
}

/// RPC error information.
public struct ACPRPCErrorInfo: Sendable, Equatable {
    public let method: String?
    public let code: Int
    public let message: String
    
    public init(method: String?, code: Int, message: String) {
        self.method = method
        self.code = code
        self.message = message
    }
}

// MARK: - Dispatch Context

/// Context needed for response dispatch decisions.
public struct ACPResponseDispatchContext: Sendable {
    /// The pending session creation placeholder ID, if any.
    public let pendingPlaceholderId: String?
    
    /// The pending working directory for session creation.
    public let pendingCwd: String?
    
    /// Transform function for working directory redaction.
    public let cwdTransform: @Sendable (String?) -> String?
    
    public init(
        pendingPlaceholderId: String? = nil,
        pendingCwd: String? = nil,
        cwdTransform: @escaping @Sendable (String?) -> String? = { $0 }
    ) {
        self.pendingPlaceholderId = pendingPlaceholderId
        self.pendingCwd = pendingCwd
        self.cwdTransform = cwdTransform
    }
}

// MARK: - Response Dispatcher

/// Dispatches JSON-RPC responses into typed actions.
/// This centralizes response parsing logic and makes it unit-testable.
public enum ACPResponseDispatcher {
    
    /// Dispatch a successful response into actions.
    /// - Parameters:
    ///   - result: The result payload from the response.
    ///   - method: The RPC method that was called (if tracked).
    ///   - context: Dispatch context with pending state.
    /// - Returns: Array of actions to apply.
    public static func dispatchSuccess(
        result: ACP.Value?,
        method: String?,
        context: ACPResponseDispatchContext
    ) -> [ACPResponseAction] {
        var actions: [ACPResponseAction] = []
        
        // Session activation (session/new, session/load, session/resume)
        if let sessionAction = parseSessionActivation(result: result, method: method, context: context) {
            // Check for placeholder migration
            if let placeholderId = context.pendingPlaceholderId,
               isSessionNewMethod(method),
               placeholderId != sessionAction.sessionId {
                actions.append(.sessionMigrated(from: placeholderId, to: sessionAction.sessionId))
            }
            
            actions.append(.sessionActivated(sessionAction))
            
            // Mark materialized for session methods
            if let method, isSessionMaterializingMethod(method) {
                actions.append(.sessionMaterialized(sessionId: sessionAction.sessionId))
            }
        }
        
        // Mode change (session/set_mode)
        if method == "session/set_mode" {
            if let setModeResult = ACPSessionResponseParser.parseSetMode(result: result) {
                actions.append(.modeChanged(modeId: setModeResult.currentModeId))
            }
        }
        
        // Initialize response
        if isInitializeResponse(method: method, result: result) {
            if let parsed = ACPInitializeParser.parse(result: result) {
                actions.append(.initialized(parsed))
            }
        }
        
        // Stop reason
        if let stopReason = result?.objectValue?["stopReason"]?.stringValue {
            actions.append(.stopReason(stopReason))
        }
        
        // Session list
        if method == "session/list" {
            let listResult = parseSessionList(result: result, context: context)
            actions.append(.sessionListReceived(listResult))
            actions.append(.capabilityConfirmed(.listSessions))
        }
        
        // Session load completion
        if method == "session/load" {
            actions.append(.sessionLoadCompleted)
        }
        
        return actions
    }
    
    /// Dispatch an error response into actions.
    /// - Parameters:
    ///   - code: The error code.
    ///   - message: The error message.
    ///   - method: The RPC method that failed.
    /// - Returns: Array of actions to apply.
    public static func dispatchError(
        code: Int,
        message: String,
        method: String?
    ) -> [ACPResponseAction] {
        var actions: [ACPResponseAction] = []
        
        let errorInfo = ACPRPCErrorInfo(method: method, code: code, message: message)
        actions.append(.rpcError(errorInfo))
        
        // Method not found (-32601) disables capabilities
        if code == -32601 {
            switch method {
            case "session/load":
                actions.append(.capabilityDisabled(.loadSession))
            case "session/resume":
                actions.append(.capabilityDisabled(.resumeSession))
            case "session/list":
                actions.append(.capabilityDisabled(.listSessions))
            default:
                break
            }
        }
        
        return actions
    }
    
    // MARK: - Private Helpers
    
    private static func isSessionNewMethod(_ method: String?) -> Bool {
        method == "session/new" || method == "session/create"
    }
    
    private static func isSessionMaterializingMethod(_ method: String) -> Bool {
        ["session/new", "session/create", "session/load", "session/resume"].contains(method)
    }
    
    private static func isInitializeResponse(method: String?, result: ACP.Value?) -> Bool {
        if method == "initialize" || method == "acp/initialize" {
            return true
        }
        // Fallback: check for agent info in result
        let resultObj = result?.objectValue
        return resultObj?["agent"] != nil || resultObj?["agentInfo"] != nil
    }
    
    private static func parseSessionActivation(
        result: ACP.Value?,
        method: String?,
        context: ACPResponseDispatchContext
    ) -> ACPSessionActivation? {
        if isSessionNewMethod(method) {
            // Use ACPSessionResponseParser for session/new
            if let parsed = ACPSessionResponseParser.parseSessionNew(
                result: result,
                fallbackCwd: context.pendingCwd
            ) {
                return ACPSessionActivation(
                    sessionId: parsed.sessionId,
                    cwd: parsed.cwd,
                    modes: parsed.modes
                )
            }
        } else if method == "session/load" || method == "session/resume" {
            // Use ACPSessionResponseParser for session/load
            if let requestedId = result?.objectValue?["sessionId"]?.stringValue
                ?? result?.objectValue?["session"]?.stringValue {
                let parsed = ACPSessionResponseParser.parseSessionLoad(
                    result: result,
                    requestedSessionId: requestedId
                )
                return ACPSessionActivation(
                    sessionId: parsed.sessionId,
                    cwd: parsed.cwd,
                    modes: parsed.modes
                )
            }
        } else if let id = result?.objectValue?["sessionId"]?.stringValue
            ?? result?.objectValue?["session"]?.stringValue {
            // Fallback for other methods that return a session ID
            let modes = ACPSessionResponseParser.parseModes(from: result?.objectValue)
            let cwd = result?.objectValue?["cwd"]?.stringValue
            return ACPSessionActivation(sessionId: id, cwd: cwd, modes: modes)
        }
        
        return nil
    }
    
    private static func parseSessionList(
        result: ACP.Value?,
        context: ACPResponseDispatchContext
    ) -> ACPSessionListResult {
        let resultObj = result?.objectValue
        let sessionsArray = resultObj?["sessions"] ?? resultObj?["items"]
        
        guard case let .array(sessions) = sessionsArray else {
            return ACPSessionListResult(sessions: [])
        }
        
        let parsedSummaries = ACPSessionListParser.parse(
            sessions: sessions,
            transformCwd: { cwd in
                context.cwdTransform(cwd) ?? cwd
            }
        )
        
        return ACPSessionListResult(sessions: parsedSummaries)
    }
}