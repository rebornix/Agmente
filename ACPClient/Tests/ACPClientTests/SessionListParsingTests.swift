import XCTest
import ACP
@testable import ACPClient

final class SessionListParsingTests: XCTestCase {
    func testParseSessionListUsesMtimeAndPrompt() {
        let sessions: [ACP.Value] = [
            .object([
                "sessionId": .string("sess-1"),
                "prompt": .string("Hello"),
                "cwd": .string("/tmp"),
                "mtime": .number(1_700_000_000_000),
            ]),
        ]

        let summaries = ACPSessionListParser.parse(sessions: sessions)

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].id, "sess-1")
        XCTAssertEqual(summaries[0].title, "Hello")
        XCTAssertEqual(summaries[0].cwd, "/tmp")
        XCTAssertNotNil(summaries[0].updatedAt)
        XCTAssertEqual(summaries[0].updatedAt?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.5)
    }

    func testParseSessionListUsesUpdatedAtString() {
        let sessions: [ACP.Value] = [
            .object([
                "sessionId": .string("sess-2"),
                "title": .string("Title"),
                "updatedAt": .string("2025-01-01T00:00:00Z"),
            ]),
        ]

        let summaries = ACPSessionListParser.parse(sessions: sessions)

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].id, "sess-2")
        XCTAssertEqual(summaries[0].title, "Title")
        XCTAssertNotNil(summaries[0].updatedAt)
        XCTAssertEqual(summaries[0].updatedAt?.timeIntervalSince1970 ?? 0, 1_735_689_600, accuracy: 0.5)
    }

    func testParseSessionListSortsByUpdatedAtDescending() {
        let sessions: [ACP.Value] = [
            .object([
                "sessionId": .string("older"),
                "mtime": .number(1_000),
            ]),
            .object([
                "sessionId": .string("newer"),
                "mtime": .number(2_000),
            ]),
        ]

        let summaries = ACPSessionListParser.parse(sessions: sessions)

        XCTAssertEqual(summaries.map(\.id), ["newer", "older"])
    }

    func testParseSessionListAppliesCwdTransform() {
        let sessions: [ACP.Value] = [
            .object([
                "sessionId": .string("sess-3"),
                "cwd": .string("/secret"),
            ]),
        ]

        let summaries = ACPSessionListParser.parse(sessions: sessions) { _ in "/redacted" }

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].cwd, "/redacted")
    }
}