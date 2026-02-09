import ACP
import XCTest
@testable import ACPClient

final class ACPMessageBuilderTests: XCTestCase {
    func testPermissionResponseSelectedBuildsOutcome() {
        let message = ACPMessageBuilder.permissionResponseSelected(requestId: .int(0), optionId: "proceed_once")

        guard case let .response(response) = message else {
            XCTFail("Expected ACP response")
            return
        }

        XCTAssertEqual(response.id, .int(0))
        let outcome = response.resultValue?.objectValue?["outcome"]?.objectValue
        XCTAssertEqual(outcome?["outcome"]?.stringValue, "selected")
        XCTAssertEqual(outcome?["optionId"]?.stringValue, "proceed_once")
    }

    func testPermissionResponseCancelledBuildsOutcome() {
        let message = ACPMessageBuilder.permissionResponseCancelled(requestId: .int(2))

        guard case let .response(response) = message else {
            XCTFail("Expected ACP response")
            return
        }

        XCTAssertEqual(response.id, .int(2))
        let outcome = response.resultValue?.objectValue?["outcome"]?.objectValue
        XCTAssertEqual(outcome?["outcome"]?.stringValue, "cancelled")
        XCTAssertNil(outcome?["optionId"])
    }

    func testInitializedNotificationBuildsMessage() {
        let message = ACPMessageBuilder.initializedNotification()

        guard case let .notification(notification) = message else {
            XCTFail("Expected ACP notification")
            return
        }

        XCTAssertEqual(notification.method, InitializedNotification.name)
        XCTAssertTrue(notification.params.isNull)
    }

    func testErrorResponseBuildsMessage() {
        let message = ACPMessageBuilder.errorResponse(requestId: .string("err-1"), code: -32001, message: "Terminal access not available.")

        guard case let .response(response) = message else {
            XCTFail("Expected ACP response")
            return
        }

        XCTAssertEqual(response.id, .string("err-1"))
        XCTAssertEqual(response.errorValue?.code, -32001)
        XCTAssertEqual(response.errorValue?.message, "Terminal access not available.")
    }
}