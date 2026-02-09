import XCTest
@testable import Agmente

final class SessionStorageTests: XCTestCase {
    func testEmptyWorkingDirectoryDoesNotPersistRootForLocalOnlyAgents() {
        let storage = SessionStorage.inMemory()
        let serverId = UUID()
        let server = ACPServerConfiguration(
            id: serverId,
            name: "Local-only",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            cfAccessClientId: "",
            cfAccessClientSecret: "",
            workingDirectory: "   "
        )

        storage.saveServer(server)

        let stored = storage.fetchServers()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, serverId)
        XCTAssertEqual(stored.first?.workingDirectory, "")
        XCTAssertTrue(storage.fetchUsedWorkingDirectories(forServerId: serverId).isEmpty)
    }
}