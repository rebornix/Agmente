import Foundation

public enum AppServerEvent: Equatable, Sendable {
    case threadStarted(thread: AppServerThreadSummary)
    case turnStarted(threadId: String?, turn: AppServerTurnSummary)
    case turnCompleted(threadId: String?, turn: AppServerTurnSummary)
    case agentMessageDelta(threadId: String?, turnId: String?, delta: String)
    case itemStarted(threadId: String?, turnId: String?, item: AppServerThreadItem)
    case itemCompleted(threadId: String?, turnId: String?, item: AppServerThreadItem)
    case diffUpdated(threadId: String?, turnId: String?, diff: String)
    case planUpdated(AppServerPlanUpdate)
    case tokenUsageUpdated(threadId: String?, turnId: String?, payload: JSONValue?)
    case approvalRequested(method: String, requestId: JSONRPCID, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case request(method: String, requestId: JSONRPCID, params: JSONValue?)
}

public struct AppServerEventParser {
    public init() {}

    public func parse(_ message: AppServerMessage) -> [AppServerEvent] {
        switch message {
        case .notification(let notification):
            return [parseNotification(notification)]
        case .request(let request):
            return [parseRequest(request)]
        case .response, .error:
            return []
        }
    }

    private func parseNotification(_ notification: JSONRPCNotification) -> AppServerEvent {
        let method = notification.method
        let params = notification.params

        switch method {
        case "thread/started":
            if let thread = parseThread(from: params) {
                return .threadStarted(thread: thread)
            }
        case "turn/started":
            if let (threadId, turn) = parseTurn(from: params) {
                return .turnStarted(threadId: threadId, turn: turn)
            }
        case "turn/completed":
            if let (threadId, turn) = parseTurn(from: params) {
                return .turnCompleted(threadId: threadId, turn: turn)
            }
        case "item/agentMessage/delta":
            if let paramsObject = params?.objectValue,
               let delta = paramsObject["delta"]?.stringValue {
                return .agentMessageDelta(
                    threadId: paramsObject["threadId"]?.stringValue,
                    turnId: paramsObject["turnId"]?.stringValue,
                    delta: delta
                )
            }
        case "item/started":
            if let event = parseItemEvent(params: params, completed: false) {
                return event
            }
        case "item/completed":
            if let event = parseItemEvent(params: params, completed: true) {
                return event
            }
        case "turn/diff/updated":
            if let paramsObject = params?.objectValue,
               let diff = paramsObject["diff"]?.stringValue {
                return .diffUpdated(
                    threadId: paramsObject["threadId"]?.stringValue,
                    turnId: paramsObject["turnId"]?.stringValue,
                    diff: diff
                )
            }
        case "turn/plan/updated":
            if let update = parsePlanUpdate(from: params) {
                return .planUpdated(update)
            }
        case "thread/tokenUsage/updated":
            if let paramsObject = params?.objectValue {
                return .tokenUsageUpdated(
                    threadId: paramsObject["threadId"]?.stringValue,
                    turnId: paramsObject["turnId"]?.stringValue,
                    payload: params
                )
            }
        default:
            break
        }

        return .notification(method: method, params: params)
    }

    private func parseRequest(_ request: JSONRPCRequest) -> AppServerEvent {
        switch request.method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            return .approvalRequested(method: request.method, requestId: request.id, params: request.params)
        default:
            return .request(method: request.method, requestId: request.id, params: request.params)
        }
    }

    private func parseThread(from params: JSONValue?) -> AppServerThreadSummary? {
        guard let object = params?.objectValue,
              let threadObject = object["thread"]?.objectValue else { return nil }
        return AppServerResponseParser.parseThreadSummary(from: threadObject)
    }

    private func parseTurn(from params: JSONValue?) -> (String?, AppServerTurnSummary)? {
        guard let object = params?.objectValue,
              let turnObject = object["turn"]?.objectValue,
              let turn = AppServerResponseParser.parseTurnSummary(from: turnObject) else { return nil }
        return (object["threadId"]?.stringValue, turn)
    }

    private func parseItemEvent(params: JSONValue?, completed: Bool) -> AppServerEvent? {
        guard let object = params?.objectValue else { return nil }
        guard let itemValue = object["item"] else { return nil }
        guard let item = AppServerThreadItem(json: itemValue) else { return nil }
        let threadId = object["threadId"]?.stringValue
        let turnId = object["turnId"]?.stringValue
        return completed
        ? .itemCompleted(threadId: threadId, turnId: turnId, item: item)
        : .itemStarted(threadId: threadId, turnId: turnId, item: item)
    }

    private func parsePlanUpdate(from params: JSONValue?) -> AppServerPlanUpdate? {
        guard let object = params?.objectValue,
              case let .array(planItems)? = object["plan"] else { return nil }
        let steps = planItems.compactMap { item -> AppServerPlanStep? in
            guard let planObject = item.objectValue,
                  let step = planObject["step"]?.stringValue,
                  let status = planObject["status"]?.stringValue else { return nil }
            return AppServerPlanStep(step: step, status: status)
        }
        return AppServerPlanUpdate(
            turnId: object["turnId"]?.stringValue,
            explanation: object["explanation"]?.stringValue,
            steps: steps
        )
    }
}