import XCTest
@testable import AppServerClient

final class EventParserTests: XCTestCase {
    func testAgentMessageDeltaEvent() {
        let params: JSONValue = .object([
            "threadId": .string("thr_1"),
            "turnId": .string("turn_1"),
            "delta": .string("hello")
        ])
        let notification = JSONRPCNotification(method: "item/agentMessage/delta", params: params)
        let message = AppServerMessage.notification(notification)

        let parser = AppServerEventParser()
        let events = parser.parse(message)

        XCTAssertEqual(events.count, 1)
        guard case .agentMessageDelta(let threadId, let turnId, let delta) = events[0] else {
            return XCTFail("Expected agentMessageDelta event")
        }
        XCTAssertEqual(threadId, "thr_1")
        XCTAssertEqual(turnId, "turn_1")
        XCTAssertEqual(delta, "hello")
    }
}