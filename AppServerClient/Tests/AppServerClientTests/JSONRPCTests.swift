import XCTest
@testable import AppServerClient

final class JSONRPCTests: XCTestCase {
    func testDecodeRequestWithoutJSONRPCHeader() throws {
        let data = "{\"id\":1,\"method\":\"thread/start\",\"params\":{}}".data(using: .utf8)
        let message = try JSONDecoder().decode(AppServerMessage.self, from: XCTUnwrap(data))
        guard case .request(let request) = message else {
            return XCTFail("Expected request")
        }
        XCTAssertEqual(request.method, "thread/start")
        XCTAssertEqual(request.id, .int(1))
    }

    func testEncodeRequestWithJSONRPCHeader() throws {
        let request = JSONRPCRequest(id: .int(1), method: "initialize", params: nil, includeJSONRPC: true)
        let message = AppServerMessage.request(request)
        let data = try JSONEncoder().encode(message)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"jsonrpc\":\"2.0\""))
    }
}