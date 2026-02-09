import XCTest
import ACP
@testable import ACPClient

final class ServiceModelTests: XCTestCase {
    
    // MARK: - ACPSessionLoadPayload Tests
    
    func testSessionLoadPayloadParams() {
        let payload = ACPSessionLoadPayload(
            sessionId: "session-123",
            workingDirectory: "/path/to/project"
        )
        
        let params = payload.params()
        
        guard case let .object(dict) = params else {
            XCTFail("Expected object params")
            return
        }
        
        XCTAssertEqual(dict["sessionId"]?.stringValue, "session-123")
        XCTAssertEqual(dict["cwd"]?.stringValue, "/path/to/project")
        if case let .array(servers) = dict["mcpServers"] {
            XCTAssertEqual(servers.count, 0)
        } else {
            XCTFail("Expected mcpServers array")
        }
    }
    
    func testSessionLoadPayloadWithMcpServers() {
        let payload = ACPSessionLoadPayload(
            sessionId: "session-456",
            workingDirectory: "/home/user",
            mcpServers: [.string("server1"), .string("server2")]
        )
        
        let params = payload.params()
        
        guard case let .object(dict) = params else {
            XCTFail("Expected object params")
            return
        }
        
        XCTAssertEqual(dict["sessionId"]?.stringValue, "session-456")
        XCTAssertEqual(dict["cwd"]?.stringValue, "/home/user")
        if case let .array(servers) = dict["mcpServers"] {
            XCTAssertEqual(servers.count, 2)
        } else {
            XCTFail("Expected mcpServers array")
        }
    }
    
    // MARK: - ACPSessionResumePayload Tests
    
    func testSessionResumePayloadParams() {
        let payload = ACPSessionResumePayload(
            sessionId: "resume-session",
            workingDirectory: "/workspace"
        )
        
        let params = payload.params()
        
        guard case let .object(dict) = params else {
            XCTFail("Expected object params")
            return
        }
        
        XCTAssertEqual(dict["sessionId"]?.stringValue, "resume-session")
        XCTAssertEqual(dict["cwd"]?.stringValue, "/workspace")
        if case let .array(servers) = dict["mcpServers"] {
            XCTAssertEqual(servers.count, 0)
        } else {
            XCTFail("Expected mcpServers array")
        }
    }
    
    // MARK: - ACPSessionCreatePayload Tests
    
    func testSessionCreatePayloadParams() {
        let payload = ACPSessionCreatePayload(
            workingDirectory: "/new/project"
        )
        
        let params = payload.params()
        
        guard case let .object(dict) = params else {
            XCTFail("Expected object params")
            return
        }
        
        XCTAssertEqual(dict["cwd"]?.stringValue, "/new/project")
        if case let .array(servers) = dict["mcpServers"] {
            XCTAssertEqual(servers.count, 0)
        } else {
            XCTFail("Expected mcpServers array")
        }
        XCTAssertNil(dict["agent"])
    }
    
    func testSessionCreatePayloadWithAgent() {
        let payload = ACPSessionCreatePayload(
            workingDirectory: "/project",
            agent: "custom-agent"
        )
        
        let params = payload.params()
        
        guard case let .object(dict) = params else {
            XCTFail("Expected object params")
            return
        }
        
        XCTAssertEqual(dict["cwd"]?.stringValue, "/project")
        XCTAssertEqual(dict["agent"]?.stringValue, "custom-agent")
    }
    
    // MARK: - ACPSessionListPayload Tests
    
    func testSessionListPayloadEmpty() {
        let payload = ACPSessionListPayload()
        
        let params = payload.params()
        
        guard case let .object(dict) = params else {
            XCTFail("Expected object params")
            return
        }
        
        XCTAssertTrue(dict.isEmpty)
    }
    
    func testSessionListPayloadWithAllOptions() {
        let payload = ACPSessionListPayload(
            limit: 50,
            cursor: "next-page",
            workingDirectory: "/workspace"
        )
        
        let params = payload.params()
        
        guard case let .object(dict) = params else {
            XCTFail("Expected object params")
            return
        }
        
        XCTAssertEqual(dict["limit"]?.numberValue, 50)
        XCTAssertEqual(dict["cursor"]?.stringValue, "next-page")
        XCTAssertEqual(dict["cwd"]?.stringValue, "/workspace")
    }
    
    // MARK: - ACPSessionSetModePayload Tests
    
    func testSessionSetModePayloadParams() {
        let payload = ACPSessionSetModePayload(
            sessionId: "mode-session",
            modeId: "code-mode"
        )
        
        let params = payload.params()
        
        guard case let .object(dict) = params else {
            XCTFail("Expected object params")
            return
        }
        
        XCTAssertEqual(dict["sessionId"]?.stringValue, "mode-session")
        XCTAssertEqual(dict["modeId"]?.stringValue, "code-mode")
    }
    
    // MARK: - ACPSessionCancelPayload Tests
    
    func testSessionCancelPayloadParams() {
        let payload = ACPSessionCancelPayload(sessionId: "cancel-session")
        
        let params = payload.params()
        
        guard case let .object(dict) = params else {
            XCTFail("Expected object params")
            return
        }
        
        XCTAssertEqual(dict["sessionId"]?.stringValue, "cancel-session")
    }
    
    // MARK: - ACPInitializationPayload Tests
    
    func testInitializationPayloadBasic() {
        let payload = ACPInitializationPayload(
            clientName: "TestClient",
            clientVersion: "1.0.0"
        )
        
        let params = payload.params()
        
        guard case let .object(dict) = params else {
            XCTFail("Expected object params")
            return
        }
        
        XCTAssertEqual(dict["protocolVersion"]?.numberValue, 1)
        
        let clientInfo = dict["clientInfo"]?.objectValue
        XCTAssertEqual(clientInfo?["name"]?.stringValue, "TestClient")
        XCTAssertEqual(clientInfo?["version"]?.stringValue, "1.0.0")
    }
    
    func testInitializationPayloadWithCapabilities() {
        let capabilities: [String: ACP.Value] = [
            "fs": .object(["readTextFile": .bool(true)]),
            "terminal": .bool(false)
        ]
        
        let payload = ACPInitializationPayload(
            clientName: "TestClient",
            clientVersion: "2.0.0",
            clientCapabilities: capabilities
        )
        
        let params = payload.params()
        
        guard case let .object(dict) = params else {
            XCTFail("Expected object params")
            return
        }
        
        let caps = dict["clientCapabilities"]?.objectValue
        XCTAssertNotNil(caps?["fs"])
        XCTAssertEqual(caps?["terminal"]?.boolValue, false)
    }
}