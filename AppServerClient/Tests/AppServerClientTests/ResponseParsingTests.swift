import XCTest
@testable import AppServerClient

final class ResponseParsingTests: XCTestCase {
    // MARK: - Skills Sorting

    func testParseSkillsListSortsByScope() {
        let result: JSONValue = .object([
            "data": .array([
                .object([
                    "skills": .array([
                        .object([
                            "name": .string("admin-skill"),
                            "description": .string("desc"),
                            "scope": .string("admin")
                        ]),
                        .object([
                            "name": .string("user-skill"),
                            "description": .string("desc"),
                            "scope": .string("user")
                        ]),
                        .object([
                            "name": .string("system-skill"),
                            "description": .string("desc"),
                            "scope": .string("system")
                        ]),
                        .object([
                            "name": .string("repo-skill"),
                            "description": .string("desc"),
                            "scope": .string("repo")
                        ])
                    ])
                ])
            ])
        ])

        let skills = AppServerResponseParser.parseSkillsList(result: result)

        XCTAssertEqual(skills.count, 4)
        XCTAssertEqual(skills[0].scope, .user)
        XCTAssertEqual(skills[1].scope, .repo)
        XCTAssertEqual(skills[2].scope, .system)
        XCTAssertEqual(skills[3].scope, .admin)
    }

    func testParseSkillsListSortsByNameWithinScope() {
        let result: JSONValue = .object([
            "data": .array([
                .object([
                    "skills": .array([
                        .object([
                            "name": .string("zebra"),
                            "description": .string("desc"),
                            "scope": .string("repo")
                        ]),
                        .object([
                            "name": .string("alpha"),
                            "description": .string("desc"),
                            "scope": .string("repo")
                        ]),
                        .object([
                            "name": .string("middle"),
                            "description": .string("desc"),
                            "scope": .string("repo")
                        ])
                    ])
                ])
            ])
        ])

        let skills = AppServerResponseParser.parseSkillsList(result: result)

        XCTAssertEqual(skills.count, 3)
        XCTAssertEqual(skills[0].name, "alpha")
        XCTAssertEqual(skills[1].name, "middle")
        XCTAssertEqual(skills[2].name, "zebra")
    }

    func testParseSkillsListSortsByScopeThenName() {
        let result: JSONValue = .object([
            "data": .array([
                .object([
                    "skills": .array([
                        .object([
                            "name": .string("b-system"),
                            "description": .string("desc"),
                            "scope": .string("system")
                        ]),
                        .object([
                            "name": .string("a-user"),
                            "description": .string("desc"),
                            "scope": .string("user")
                        ]),
                        .object([
                            "name": .string("a-system"),
                            "description": .string("desc"),
                            "scope": .string("system")
                        ]),
                        .object([
                            "name": .string("b-user"),
                            "description": .string("desc"),
                            "scope": .string("user")
                        ])
                    ])
                ])
            ])
        ])

        let skills = AppServerResponseParser.parseSkillsList(result: result)

        XCTAssertEqual(skills.count, 4)
        XCTAssertEqual(skills[0].name, "a-user")
        XCTAssertEqual(skills[0].scope, .user)
        XCTAssertEqual(skills[1].name, "b-user")
        XCTAssertEqual(skills[1].scope, .user)
        XCTAssertEqual(skills[2].name, "a-system")
        XCTAssertEqual(skills[2].scope, .system)
        XCTAssertEqual(skills[3].name, "b-system")
        XCTAssertEqual(skills[3].scope, .system)
    }

    // MARK: - AppServerSkillScope Comparable

    func testSkillScopeComparable() {
        XCTAssertTrue(AppServerSkillScope.user < AppServerSkillScope.repo)
        XCTAssertTrue(AppServerSkillScope.repo < AppServerSkillScope.system)
        XCTAssertTrue(AppServerSkillScope.system < AppServerSkillScope.admin)
        XCTAssertFalse(AppServerSkillScope.admin < AppServerSkillScope.user)
    }
}
