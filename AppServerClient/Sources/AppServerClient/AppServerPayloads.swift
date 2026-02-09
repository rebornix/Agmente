import Foundation

public struct AppServerClientInfo: Equatable, Sendable {
    public var name: String
    public var title: String?
    public var version: String

    public init(name: String, title: String? = nil, version: String) {
        self.name = name
        self.title = title
        self.version = version
    }

    func params() -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "version": .string(version),
        ]
        if let title {
            object["title"] = .string(title)
        }
        return .object(object)
    }
}

public struct AppServerInitializePayload: Equatable, Sendable {
    public var clientInfo: AppServerClientInfo

    public init(clientInfo: AppServerClientInfo) {
        self.clientInfo = clientInfo
    }

    func params() -> JSONValue {
        .object([
            "clientInfo": clientInfo.params(),
        ])
    }
}

public struct AppServerApprovalPolicy: RawRepresentable, Equatable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let unlessTrusted = AppServerApprovalPolicy(rawValue: "unlessTrusted")
    public static let untrusted = AppServerApprovalPolicy(rawValue: "untrusted")
    public static let onRequest = AppServerApprovalPolicy(rawValue: "onRequest")
    public static let onFailure = AppServerApprovalPolicy(rawValue: "onFailure")
    public static let never = AppServerApprovalPolicy(rawValue: "never")
}

public struct AppServerSandboxMode: RawRepresentable, Equatable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let readOnly = AppServerSandboxMode(rawValue: "readOnly")
    public static let workspaceWrite = AppServerSandboxMode(rawValue: "workspaceWrite")
    public static let dangerFullAccess = AppServerSandboxMode(rawValue: "dangerFullAccess")
}

public struct AppServerSandboxPolicy: Equatable, Sendable {
    public var type: String
    public var fields: [String: JSONValue]

    public init(type: String, fields: [String: JSONValue] = [:]) {
        self.type = type
        self.fields = fields
    }

    public static func readOnly() -> AppServerSandboxPolicy {
        AppServerSandboxPolicy(type: "readOnly")
    }

    public static func dangerFullAccess() -> AppServerSandboxPolicy {
        AppServerSandboxPolicy(type: "dangerFullAccess")
    }

    public static func workspaceWrite(writableRoots: [String]? = nil, networkAccess: Bool? = nil) -> AppServerSandboxPolicy {
        var fields: [String: JSONValue] = [:]
        if let writableRoots, !writableRoots.isEmpty {
            fields["writableRoots"] = .array(writableRoots.map { .string($0) })
        }
        if let networkAccess {
            fields["networkAccess"] = .bool(networkAccess)
        }
        return AppServerSandboxPolicy(type: "workspaceWrite", fields: fields)
    }

    public static func externalSandbox(networkAccess: String? = nil) -> AppServerSandboxPolicy {
        var fields: [String: JSONValue] = [:]
        if let networkAccess {
            fields["networkAccess"] = .string(networkAccess)
        }
        return AppServerSandboxPolicy(type: "externalSandbox", fields: fields)
    }

    func params() -> JSONValue {
        var object: [String: JSONValue] = ["type": .string(type)]
        fields.forEach { object[$0.key] = $0.value }
        return .object(object)
    }
}

public struct AppServerReasoningEffort: RawRepresentable, Equatable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let minimal = AppServerReasoningEffort(rawValue: "minimal")
    public static let low = AppServerReasoningEffort(rawValue: "low")
    public static let medium = AppServerReasoningEffort(rawValue: "medium")
    public static let high = AppServerReasoningEffort(rawValue: "high")
}

public struct AppServerReasoningSummary: RawRepresentable, Equatable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let concise = AppServerReasoningSummary(rawValue: "concise")
    public static let detailed = AppServerReasoningSummary(rawValue: "detailed")
}

public struct AppServerThreadStartPayload: Equatable, Sendable {
    public var model: String?
    public var modelProvider: String?
    public var cwd: String?
    public var approvalPolicy: AppServerApprovalPolicy?
    public var sandbox: AppServerSandboxMode?
    public var config: [String: JSONValue]?
    public var baseInstructions: String?
    public var developerInstructions: String?

    public init(
        model: String? = nil,
        modelProvider: String? = nil,
        cwd: String? = nil,
        approvalPolicy: AppServerApprovalPolicy? = nil,
        sandbox: AppServerSandboxMode? = nil,
        config: [String: JSONValue]? = nil,
        baseInstructions: String? = nil,
        developerInstructions: String? = nil
    ) {
        self.model = model
        self.modelProvider = modelProvider
        self.cwd = cwd
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.config = config
        self.baseInstructions = baseInstructions
        self.developerInstructions = developerInstructions
    }

    func params() -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let model { object["model"] = .string(model) }
        if let modelProvider { object["modelProvider"] = .string(modelProvider) }
        if let cwd { object["cwd"] = .string(cwd) }
        if let approvalPolicy { object["approvalPolicy"] = .string(approvalPolicy.rawValue) }
        if let sandbox { object["sandbox"] = .string(sandbox.rawValue) }
        if let config { object["config"] = .object(config) }
        if let baseInstructions { object["baseInstructions"] = .string(baseInstructions) }
        if let developerInstructions { object["developerInstructions"] = .string(developerInstructions) }
        return .object(object)
    }
}

public struct AppServerThreadResumePayload: Equatable, Sendable {
    public var threadId: String
    public var model: String?
    public var modelProvider: String?
    public var cwd: String?
    public var approvalPolicy: AppServerApprovalPolicy?
    public var sandbox: AppServerSandboxMode?
    public var config: [String: JSONValue]?
    public var baseInstructions: String?
    public var developerInstructions: String?

    public init(
        threadId: String,
        model: String? = nil,
        modelProvider: String? = nil,
        cwd: String? = nil,
        approvalPolicy: AppServerApprovalPolicy? = nil,
        sandbox: AppServerSandboxMode? = nil,
        config: [String: JSONValue]? = nil,
        baseInstructions: String? = nil,
        developerInstructions: String? = nil
    ) {
        self.threadId = threadId
        self.model = model
        self.modelProvider = modelProvider
        self.cwd = cwd
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.config = config
        self.baseInstructions = baseInstructions
        self.developerInstructions = developerInstructions
    }

    func params() -> JSONValue {
        var object: [String: JSONValue] = ["threadId": .string(threadId)]
        if let model { object["model"] = .string(model) }
        if let modelProvider { object["modelProvider"] = .string(modelProvider) }
        if let cwd { object["cwd"] = .string(cwd) }
        if let approvalPolicy { object["approvalPolicy"] = .string(approvalPolicy.rawValue) }
        if let sandbox { object["sandbox"] = .string(sandbox.rawValue) }
        if let config { object["config"] = .object(config) }
        if let baseInstructions { object["baseInstructions"] = .string(baseInstructions) }
        if let developerInstructions { object["developerInstructions"] = .string(developerInstructions) }
        return .object(object)
    }
}

public struct AppServerThreadListPayload: Equatable, Sendable {
    public var cursor: String?
    public var limit: Int?
    public var modelProviders: [String]?

    public init(cursor: String? = nil, limit: Int? = nil, modelProviders: [String]? = nil) {
        self.cursor = cursor
        self.limit = limit
        self.modelProviders = modelProviders
    }

    func params() -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let cursor { object["cursor"] = .string(cursor) }
        if let limit { object["limit"] = .number(Double(limit)) }
        if let modelProviders { object["modelProviders"] = .array(modelProviders.map { .string($0) }) }
        return .object(object)
    }
}

public struct AppServerThreadArchivePayload: Equatable, Sendable {
    public var threadId: String

    public init(threadId: String) {
        self.threadId = threadId
    }

    func params() -> JSONValue {
        .object(["threadId": .string(threadId)])
    }
}

public enum AppServerUserInput: Equatable, Sendable {
    case text(String)
    case image(url: String)
    case localImage(path: String)

    func params() -> JSONValue {
        switch self {
        case .text(let text):
            return .object(["type": .string("text"), "text": .string(text)])
        case .image(let url):
            return .object(["type": .string("image"), "url": .string(url)])
        case .localImage(let path):
            return .object(["type": .string("localImage"), "path": .string(path)])
        }
    }
}

public struct AppServerTurnStartPayload: Equatable, Sendable {
    public var threadId: String
    public var input: [AppServerUserInput]
    public var cwd: String?
    public var approvalPolicy: AppServerApprovalPolicy?
    public var sandboxPolicy: AppServerSandboxPolicy?
    public var model: String?
    public var effort: AppServerReasoningEffort?
    public var summary: AppServerReasoningSummary?

    public init(
        threadId: String,
        input: [AppServerUserInput],
        cwd: String? = nil,
        approvalPolicy: AppServerApprovalPolicy? = nil,
        sandboxPolicy: AppServerSandboxPolicy? = nil,
        model: String? = nil,
        effort: AppServerReasoningEffort? = nil,
        summary: AppServerReasoningSummary? = nil
    ) {
        self.threadId = threadId
        self.input = input
        self.cwd = cwd
        self.approvalPolicy = approvalPolicy
        self.sandboxPolicy = sandboxPolicy
        self.model = model
        self.effort = effort
        self.summary = summary
    }

    func params() -> JSONValue {
        var object: [String: JSONValue] = [
            "threadId": .string(threadId),
            "input": .array(input.map { $0.params() }),
        ]
        if let cwd { object["cwd"] = .string(cwd) }
        if let approvalPolicy { object["approvalPolicy"] = .string(approvalPolicy.rawValue) }
        if let sandboxPolicy { object["sandboxPolicy"] = sandboxPolicy.params() }
        if let model { object["model"] = .string(model) }
        if let effort { object["effort"] = .string(effort.rawValue) }
        if let summary { object["summary"] = .string(summary.rawValue) }
        return .object(object)
    }
}

public struct AppServerTurnInterruptPayload: Equatable, Sendable {
    public var threadId: String
    public var turnId: String

    public init(threadId: String, turnId: String) {
        self.threadId = threadId
        self.turnId = turnId
    }

    func params() -> JSONValue {
        .object([
            "threadId": .string(threadId),
            "turnId": .string(turnId),
        ])
    }
}

public struct AppServerReviewDelivery: RawRepresentable, Equatable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let inline = AppServerReviewDelivery(rawValue: "inline")
    public static let detached = AppServerReviewDelivery(rawValue: "detached")
}

public enum AppServerReviewTarget: Equatable, Sendable {
    case uncommittedChanges
    case baseBranch(branch: String)
    case commit(sha: String, title: String?)
    case custom(instructions: String)

    func params() -> JSONValue {
        switch self {
        case .uncommittedChanges:
            return .object(["type": .string("uncommittedChanges")])
        case .baseBranch(let branch):
            return .object(["type": .string("baseBranch"), "branch": .string(branch)])
        case .commit(let sha, let title):
            var object: [String: JSONValue] = ["type": .string("commit"), "sha": .string(sha)]
            if let title { object["title"] = .string(title) }
            return .object(object)
        case .custom(let instructions):
            return .object(["type": .string("custom"), "instructions": .string(instructions)])
        }
    }
}

public struct AppServerReviewStartPayload: Equatable, Sendable {
    public var threadId: String
    public var target: AppServerReviewTarget
    public var delivery: AppServerReviewDelivery?

    public init(threadId: String, target: AppServerReviewTarget, delivery: AppServerReviewDelivery? = nil) {
        self.threadId = threadId
        self.target = target
        self.delivery = delivery
    }

    func params() -> JSONValue {
        var object: [String: JSONValue] = [
            "threadId": .string(threadId),
            "target": target.params(),
        ]
        if let delivery { object["delivery"] = .string(delivery.rawValue) }
        return .object(object)
    }
}

public struct AppServerCommandExecPayload: Equatable, Sendable {
    public var command: [String]
    public var cwd: String?
    public var sandboxPolicy: AppServerSandboxPolicy?
    public var timeoutMs: Int?

    public init(command: [String], cwd: String? = nil, sandboxPolicy: AppServerSandboxPolicy? = nil, timeoutMs: Int? = nil) {
        self.command = command
        self.cwd = cwd
        self.sandboxPolicy = sandboxPolicy
        self.timeoutMs = timeoutMs
    }

    func params() -> JSONValue {
        var object: [String: JSONValue] = [
            "command": .array(command.map { .string($0) }),
        ]
        if let cwd { object["cwd"] = .string(cwd) }
        if let sandboxPolicy { object["sandboxPolicy"] = sandboxPolicy.params() }
        if let timeoutMs { object["timeoutMs"] = .number(Double(timeoutMs)) }
        return .object(object)
    }
}

public struct AppServerModelListPayload: Equatable, Sendable {
    public var pageSize: Int?
    public var cursor: String?

    public init(pageSize: Int? = nil, cursor: String? = nil) {
        self.pageSize = pageSize
        self.cursor = cursor
    }

    func params() -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let pageSize { object["pageSize"] = .number(Double(pageSize)) }
        if let cursor { object["cursor"] = .string(cursor) }
        return .object(object)
    }
}

public struct AppServerSkillsListPayload: Equatable, Sendable {
    public var cwds: [String]
    public var forceReload: Bool

    public init(cwds: [String] = [], forceReload: Bool = false) {
        self.cwds = cwds
        self.forceReload = forceReload
    }

    func params() -> JSONValue {
        var object: [String: JSONValue] = [:]
        if !cwds.isEmpty {
            object["cwds"] = .array(cwds.map { .string($0) })
        }
        if forceReload {
            object["forceReload"] = .bool(forceReload)
        }
        return .object(object)
    }
}

public struct AppServerConfigReadPayload: Equatable, Sendable {
    public var includeLayers: Bool

    public init(includeLayers: Bool = false) {
        self.includeLayers = includeLayers
    }

    func params() -> JSONValue {
        .object(["includeLayers": .bool(includeLayers)])
    }
}

public struct AppServerMergeStrategy: RawRepresentable, Equatable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let replace = AppServerMergeStrategy(rawValue: "replace")
    public static let upsert = AppServerMergeStrategy(rawValue: "upsert")
}

public struct AppServerConfigValueWritePayload: Equatable, Sendable {
    public var keyPath: String
    public var value: JSONValue
    public var mergeStrategy: AppServerMergeStrategy
    public var filePath: String?
    public var expectedVersion: String?

    public init(
        keyPath: String,
        value: JSONValue,
        mergeStrategy: AppServerMergeStrategy,
        filePath: String? = nil,
        expectedVersion: String? = nil
    ) {
        self.keyPath = keyPath
        self.value = value
        self.mergeStrategy = mergeStrategy
        self.filePath = filePath
        self.expectedVersion = expectedVersion
    }

    func params() -> JSONValue {
        var object: [String: JSONValue] = [
            "keyPath": .string(keyPath),
            "value": value,
            "mergeStrategy": .string(mergeStrategy.rawValue),
        ]
        if let filePath { object["filePath"] = .string(filePath) }
        if let expectedVersion { object["expectedVersion"] = .string(expectedVersion) }
        return .object(object)
    }
}

public struct AppServerConfigEdit: Equatable, Sendable {
    public var keyPath: String
    public var value: JSONValue
    public var mergeStrategy: AppServerMergeStrategy

    public init(keyPath: String, value: JSONValue, mergeStrategy: AppServerMergeStrategy) {
        self.keyPath = keyPath
        self.value = value
        self.mergeStrategy = mergeStrategy
    }

    func params() -> JSONValue {
        .object([
            "keyPath": .string(keyPath),
            "value": value,
            "mergeStrategy": .string(mergeStrategy.rawValue),
        ])
    }
}

public struct AppServerConfigBatchWritePayload: Equatable, Sendable {
    public var edits: [AppServerConfigEdit]
    public var filePath: String?
    public var expectedVersion: String?

    public init(edits: [AppServerConfigEdit], filePath: String? = nil, expectedVersion: String? = nil) {
        self.edits = edits
        self.filePath = filePath
        self.expectedVersion = expectedVersion
    }

    func params() -> JSONValue {
        var object: [String: JSONValue] = [
            "edits": .array(edits.map { $0.params() })
        ]
        if let filePath { object["filePath"] = .string(filePath) }
        if let expectedVersion { object["expectedVersion"] = .string(expectedVersion) }
        return .object(object)
    }
}