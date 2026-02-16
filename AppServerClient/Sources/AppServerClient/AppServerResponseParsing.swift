import Foundation

public struct AppServerInitializeResult: Equatable, Sendable {
    public let userAgent: String
}

// MARK: - Model List Types

public struct AppServerReasoningEffortOption: Equatable, Sendable, Identifiable {
    public let reasoningEffort: String
    public let description: String

    public var id: String { reasoningEffort }

    public init(reasoningEffort: String, description: String) {
        self.reasoningEffort = reasoningEffort
        self.description = description
    }
}

public struct AppServerModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let model: String
    public let displayName: String
    public let description: String
    public let supportedReasoningEfforts: [AppServerReasoningEffortOption]
    public let defaultReasoningEffort: String
    public let isDefault: Bool

    public init(
        id: String,
        model: String,
        displayName: String,
        description: String,
        supportedReasoningEfforts: [AppServerReasoningEffortOption],
        defaultReasoningEffort: String,
        isDefault: Bool
    ) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.description = description
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.isDefault = isDefault
    }
}

public struct AppServerModelListResult: Equatable, Sendable {
    public let models: [AppServerModel]
    public let nextCursor: String?
}

// MARK: - Skills

public enum AppServerSkillScope: String, Equatable, Sendable, Comparable, CaseIterable {
    case user
    case repo
    case system
    case admin

    /// Defines a stable display order: user → repo → system → admin.
    private var sortOrder: Int {
        switch self {
        case .user: return 0
        case .repo: return 1
        case .system: return 2
        case .admin: return 3
        }
    }

    public static func < (lhs: AppServerSkillScope, rhs: AppServerSkillScope) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    /// Human-readable label used as a section header in the skills picker.
    public var displayName: String {
        switch self {
        case .user: return "User"
        case .repo: return "Repository"
        case .system: return "System"
        case .admin: return "Admin"
        }
    }
}

public struct AppServerSkill: Equatable, Sendable, Identifiable, Hashable {
    public let name: String
    public let description: String
    public let shortDescription: String?
    public let path: String
    public let scope: AppServerSkillScope

    public var id: String { name }

    public init(
        name: String,
        description: String,
        shortDescription: String?,
        path: String,
        scope: AppServerSkillScope
    ) {
        self.name = name
        self.description = description
        self.shortDescription = shortDescription
        self.path = path
        self.scope = scope
    }
}

// MARK: - Thread Types

public struct AppServerThreadSummary: Equatable, Sendable {
    public let id: String
    public let preview: String?
    public let modelProvider: String?
    public let createdAt: Date?
}

public struct AppServerThreadListResult: Equatable, Sendable {
    public let threads: [AppServerThreadSummary]
    public let nextCursor: String?
}

public struct AppServerThreadTurn: Equatable, Sendable {
    public let id: String
    public let status: AppServerTurnStatus?
    public let items: [AppServerThreadItem]
}

public struct AppServerThreadResumeResult: Equatable, Sendable {
    public let id: String
    public let preview: String?
    public let cwd: String?
    public let createdAt: Date?
    public let turns: [AppServerThreadTurn]
}

public struct AppServerTurnSummary: Equatable, Sendable {
    public let id: String
    public let status: AppServerTurnStatus?
}

public struct AppServerThreadItem: Equatable, Sendable {
    public let type: String
    public let id: String?
    public let payload: [String: JSONValue]

    public init(type: String, id: String?, payload: [String: JSONValue]) {
        self.type = type
        self.id = id
        self.payload = payload
    }

    public init?(json: JSONValue) {
        guard let object = json.objectValue else { return nil }
        guard let type = object["type"]?.stringValue else { return nil }
        let id = object["id"]?.stringValue
        self.type = type
        self.id = id
        self.payload = object
    }
}

public struct AppServerPlanStep: Equatable, Sendable {
    public let step: String
    public let status: String
}

public struct AppServerPlanUpdate: Equatable, Sendable {
    public let turnId: String?
    public let explanation: String?
    public let steps: [AppServerPlanStep]
}

public enum AppServerTurnStatus: Equatable, Sendable {
    case inProgress
    case completed
    case interrupted
    case failed
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "inProgress":
            self = .inProgress
        case "completed":
            self = .completed
        case "interrupted":
            self = .interrupted
        case "failed":
            self = .failed
        default:
            self = .unknown(rawValue)
        }
    }
}

public enum AppServerResponseParser {
    // MARK: - Initialize

    public static func parseInitialize(result: JSONValue?) -> AppServerInitializeResult? {
        guard let object = result?.objectValue else { return nil }
        guard let userAgent = object["userAgent"]?.stringValue else { return nil }
        return AppServerInitializeResult(userAgent: userAgent)
    }

    // MARK: - Model List

    public static func parseModelList(result: JSONValue?) -> AppServerModelListResult? {
        guard let object = result?.objectValue else { return nil }
        guard case let .array(data)? = object["data"] else { return nil }
        let models = data.compactMap { modelValue -> AppServerModel? in
            guard let model = modelValue.objectValue else { return nil }
            return parseModel(from: model)
        }
        let nextCursor = object["nextCursor"]?.stringValue
        return AppServerModelListResult(models: models, nextCursor: nextCursor)
    }

    public static func parseModel(from object: [String: JSONValue]) -> AppServerModel? {
        guard let id = object["id"]?.stringValue else { return nil }
        guard let model = object["model"]?.stringValue else { return nil }
        let displayName = object["displayName"]?.stringValue ?? model
        let description = object["description"]?.stringValue ?? ""
        let isDefault = object["isDefault"]?.boolValue ?? false
        let defaultReasoningEffort = object["defaultReasoningEffort"]?.stringValue ?? "medium"

        var supportedEfforts: [AppServerReasoningEffortOption] = []
        if case let .array(effortsArray)? = object["supportedReasoningEfforts"] {
            supportedEfforts = effortsArray.compactMap { effortValue -> AppServerReasoningEffortOption? in
                guard let effortObj = effortValue.objectValue else { return nil }
                guard let effort = effortObj["reasoningEffort"]?.stringValue else { return nil }
                let desc = effortObj["description"]?.stringValue ?? ""
                return AppServerReasoningEffortOption(reasoningEffort: effort, description: desc)
            }
        }

        return AppServerModel(
            id: id,
            model: model,
            displayName: displayName,
            description: description,
            supportedReasoningEfforts: supportedEfforts,
            defaultReasoningEffort: defaultReasoningEffort,
            isDefault: isDefault
        )
    }

    // MARK: - Skills

    public static func parseSkillsList(result: JSONValue?) -> [AppServerSkill] {
        guard let object = result?.objectValue else { return [] }
        guard case let .array(data)? = object["data"] else { return [] }

        var all: [AppServerSkill] = []
        for entry in data {
            guard let entryObj = entry.objectValue else { continue }
            guard case let .array(skillsArray)? = entryObj["skills"] else { continue }

            for skillValue in skillsArray {
                guard let skillObj = skillValue.objectValue else { continue }
                guard let name = skillObj["name"]?.stringValue else { continue }
                let description = skillObj["description"]?.stringValue ?? ""
                let shortDescription = skillObj["shortDescription"]?.stringValue
                let path = skillObj["path"]?.stringValue ?? ""
                let scopeStr = skillObj["scope"]?.stringValue ?? "repo"
                let scope = AppServerSkillScope(rawValue: scopeStr) ?? .repo

                all.append(AppServerSkill(
                    name: name,
                    description: description,
                    shortDescription: shortDescription,
                    path: path,
                    scope: scope
                ))
            }
        }

        return all.sorted { ($0.scope, $0.name) < ($1.scope, $1.name) }
    }

    // MARK: - Thread List

    public static func parseThreadList(result: JSONValue?) -> AppServerThreadListResult? {
        guard let object = result?.objectValue else { return nil }
        guard case let .array(data)? = object["data"] else { return nil }
        let threads = data.compactMap { threadValue -> AppServerThreadSummary? in
            guard let thread = threadValue.objectValue else { return nil }
            return parseThreadSummary(from: thread)
        }
        let nextCursor = object["nextCursor"]?.stringValue
        return AppServerThreadListResult(threads: threads, nextCursor: nextCursor)
    }

    public static func parseThreadStart(result: JSONValue?) -> AppServerThreadSummary? {
        guard let object = result?.objectValue else { return nil }
        guard let threadObject = object["thread"]?.objectValue else { return nil }
        return parseThreadSummary(from: threadObject)
    }

    public static func parseTurnStart(result: JSONValue?) -> AppServerTurnSummary? {
        guard let object = result?.objectValue else { return nil }
        guard let turnObject = object["turn"]?.objectValue else { return nil }
        return parseTurnSummary(from: turnObject)
    }

    public static func parseThreadSummary(from object: [String: JSONValue]) -> AppServerThreadSummary? {
        guard let id = object["id"]?.stringValue, !id.isEmpty else { return nil }
        let preview = object["preview"]?.stringValue
        let modelProvider = object["modelProvider"]?.stringValue
        let createdAtSeconds = object["createdAt"]?.numberValue.map { Int($0) }
        let createdAt = createdAtSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return AppServerThreadSummary(id: id, preview: preview, modelProvider: modelProvider, createdAt: createdAt)
    }

    public static func parseTurnSummary(from object: [String: JSONValue]) -> AppServerTurnSummary? {
        guard let id = object["id"]?.stringValue, !id.isEmpty else { return nil }
        let statusValue = object["status"]?.stringValue
        let status = statusValue.map { AppServerTurnStatus(rawValue: $0) }
        return AppServerTurnSummary(id: id, status: status)
    }

    public static func parseThreadResume(result: JSONValue?) -> AppServerThreadResumeResult? {
        guard let object = result?.objectValue else { return nil }
        guard let thread = object["thread"]?.objectValue else { return nil }
        guard let id = thread["id"]?.stringValue, !id.isEmpty else { return nil }

        let preview = thread["preview"]?.stringValue
        let cwd = thread["cwd"]?.stringValue ?? object["cwd"]?.stringValue
        let createdAtSeconds = thread["createdAt"]?.numberValue.map { Int($0) }
        let createdAt = createdAtSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }

        var turns: [AppServerThreadTurn] = []
        if case let .array(turnsArray)? = thread["turns"] {
            for turnValue in turnsArray {
                guard let turnObj = turnValue.objectValue else { continue }
                guard let turnId = turnObj["id"]?.stringValue else { continue }
                let statusValue = turnObj["status"]?.stringValue
                let status = statusValue.map { AppServerTurnStatus(rawValue: $0) }

                var items: [AppServerThreadItem] = []
                if case let .array(itemsArray)? = turnObj["items"] {
                    for itemValue in itemsArray {
                        if let item = AppServerThreadItem(json: itemValue) {
                            items.append(item)
                        }
                    }
                }

                turns.append(AppServerThreadTurn(id: turnId, status: status, items: items))
            }
        }

        return AppServerThreadResumeResult(
            id: id,
            preview: preview,
            cwd: cwd,
            createdAt: createdAt,
            turns: turns
        )
    }
}