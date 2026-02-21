import XCTest
import ACP
@testable import Agmente
import ACPClient

@MainActor
final class CodexThreadReadMergeFixtureTests: XCTestCase {

    func testThreadReadMergeFixturesFromArtifacts() throws {
        let fixtureURLs = try loadFixtureURLs()
        XCTAssertFalse(fixtureURLs.isEmpty, "Expected at least one fixture file")

        for fixtureURL in fixtureURLs {
            let fixture = try loadFixture(from: fixtureURL)
            let codexVM = makeCodexViewModel()

            try XCTContext.runActivity(named: fixture.name) { _ in
                try runFixture(fixture, on: codexVM)
            }
        }
    }

    // MARK: - Fixture Runner

    private func runFixture(_ fixture: CodexThreadReadMergeFixture, on codexVM: CodexServerViewModel) throws {
        let initialMessages = try fixture.initialMessages.map(makeChatMessage)
        let keySeeds = fixture.initialKeys.map {
            CodexServerViewModel.MergeTestKeySeed(messageIndex: $0.index, key: $0.key)
        }

        codexVM.seedMergeStateForTesting(
            threadId: fixture.threadId,
            messages: initialMessages,
            keySeeds: keySeeds,
            activeTurnId: fixture.initialActiveTurnId
        )

        for (index, step) in fixture.steps.enumerated() {
            switch step.kind {
            case .threadRead:
                guard let resultObject = step.result?.object else {
                    XCTFail("Fixture step \(index) missing thread_read.result")
                    continue
                }
                let applied = codexVM.applyThreadReadMergeForTesting(
                    resultObject: resultObject.mapValues { $0.toJSONValue() },
                    preferLocalRichness: step.preferLocalRichness ?? true
                )
                XCTAssertTrue(applied, "Failed to apply thread_read fixture at step \(index)")

            case .update:
                guard let method = step.method, !method.isEmpty else {
                    XCTFail("Fixture step \(index) missing update.method")
                    continue
                }
                let params = step.params?.toJSONValue()
                let notification = JSONRPCMessage.notification(
                    JSONRPCNotification(method: method, params: params)
                )
                codexVM.handleCodexMessage(notification)
            }
        }

        let messages = codexVM.mergedMessagesForTesting()
        if let expectedCount = fixture.expectations.messageCount {
            XCTAssertEqual(messages.count, expectedCount, "Unexpected message count for fixture \(fixture.name)")
        }

        assertOrderedMessages(
            fixture.expectations.orderedMessages,
            in: messages,
            fixtureName: fixture.name
        )

        for expected in fixture.expectations.containsCounts {
            let role = expected.role.flatMap(ChatMessage.Role.init(rawValue:))
            let count = messages.filter { message in
                if let role, message.role != role {
                    return false
                }
                return message.content.contains(expected.contains)
            }.count
            XCTAssertEqual(
                count,
                expected.count,
                "Expected \(expected.count) message(s) containing '\(expected.contains)' in fixture \(fixture.name), found \(count)"
            )
        }
    }

    private func assertOrderedMessages(
        _ expected: [CodexThreadReadMergeFixture.OrderedExpectation],
        in messages: [ChatMessage],
        fixtureName: String
    ) {
        guard !expected.isEmpty else { return }

        var searchStart = 0
        for item in expected {
            let role = ChatMessage.Role(rawValue: item.role)
            guard let role else {
                XCTFail("Invalid role '\(item.role)' in fixture \(fixtureName)")
                continue
            }

            var foundIndex: Int?
            if searchStart < messages.count {
                for index in searchStart..<messages.count {
                    let message = messages[index]
                    guard message.role == role else { continue }
                    guard message.content.contains(item.contains) else { continue }
                    foundIndex = index
                    break
                }
            }

            guard let foundIndex else {
                XCTFail("Could not find ordered message role=\(role.rawValue) contains='\(item.contains)' in fixture \(fixtureName)")
                return
            }
            searchStart = foundIndex + 1
        }
    }

    // MARK: - Fixture Loading

    private func loadFixtureURLs() throws -> [URL] {
        let fixturesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("CodexThreadReadMerge")

        let urls = try FileManager.default.contentsOfDirectory(
            at: fixturesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func loadFixture(from url: URL) throws -> CodexThreadReadMergeFixture {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CodexThreadReadMergeFixture.self, from: data)
    }

    private func makeChatMessage(_ fixture: CodexThreadReadMergeFixture.Message) throws -> ChatMessage {
        guard let role = ChatMessage.Role(rawValue: fixture.role) else {
            throw FixtureError.invalidRole(fixture.role)
        }

        let segments: [AssistantSegment] = (fixture.segments ?? []).map { segment in
            let kind = AssistantSegment.Kind(rawValue: segment.kind) ?? .message
            let toolCall = segment.toolCall.map {
                ToolCallDisplay(
                    toolCallId: $0.toolCallId,
                    title: $0.title,
                    kind: $0.kind,
                    status: $0.status,
                    output: $0.output,
                    permissionOptions: nil,
                    acpPermissionRequestId: nil,
                    permissionRequestId: nil,
                    approvalRequestId: nil,
                    approvalKind: nil,
                    approvalReason: nil,
                    approvalCommand: nil,
                    approvalCwd: nil
                )
            }
            return AssistantSegment(
                kind: kind,
                text: segment.text ?? toolCall?.title ?? "",
                toolCall: toolCall
            )
        }

        return ChatMessage(
            role: role,
            content: fixture.content,
            isStreaming: fixture.isStreaming ?? false,
            segments: segments,
            isError: fixture.isError ?? false
        )
    }

    // MARK: - ViewModel Setup

    private func makeModel() -> AppViewModel {
        let suiteName = "CodexThreadReadMergeFixtureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let storage = SessionStorage.inMemory()
        return AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
    }

    private func addServer(to model: AppViewModel, agentInfo: AgentProfile? = nil) {
        model.addServer(
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            cfAccessClientId: "",
            cfAccessClientSecret: "",
            workingDirectory: "/",
            agentInfo: agentInfo
        )
    }

    private func makeService() -> ACPService {
        let url = URL(string: "ws://localhost:1234")!
        let config = ACPClientConfiguration(endpoint: url, pingInterval: nil)
        let client = ACPClient(configuration: config)
        return ACPService(client: client)
    }

    private func makeCodexViewModel() -> CodexServerViewModel {
        let model = makeModel()
        addServer(to: model)
        let service = makeService()

        let initRequest = ACP.AnyRequest(id: .int(1), method: "initialize", params: nil)
        model.acpService(service, willSend: initRequest)

        let result: ACP.Value = .object([
            "userAgent": .string("codex/1.0.0")
        ])
        let response = ACPWireMessage.response(ACP.AnyResponse(id: .int(1), result: result))
        model.acpService(service, didReceiveMessage: response)

        guard let codexVM = model.selectedCodexServerViewModel else {
            fatalError("Expected CodexServerViewModel")
        }
        return codexVM
    }

    private enum FixtureError: Error {
        case invalidRole(String)
    }
}

private struct CodexThreadReadMergeFixture: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
        let isStreaming: Bool?
        let isError: Bool?
        let segments: [Segment]?

        struct Segment: Decodable {
            let kind: String
            let text: String?
            let toolCall: ToolCall?

            struct ToolCall: Decodable {
                let toolCallId: String?
                let title: String
                let kind: String?
                let status: String?
                let output: String?
            }
        }
    }

    struct KeySeed: Decodable {
        let index: Int
        let key: String
    }

    struct OrderedExpectation: Decodable {
        let role: String
        let contains: String
    }

    struct ContainsCountExpectation: Decodable {
        let role: String?
        let contains: String
        let count: Int
    }

    struct Expectations: Decodable {
        let messageCount: Int?
        let orderedMessages: [OrderedExpectation]
        let containsCounts: [ContainsCountExpectation]
    }

    struct Step: Decodable {
        enum Kind: String, Decodable {
            case threadRead = "thread_read"
            case update
        }

        let kind: Kind
        let preferLocalRichness: Bool?
        let result: FixtureValue?
        let method: String?
        let params: FixtureValue?
    }

    let name: String
    let threadId: String
    let initialActiveTurnId: String?
    let initialMessages: [Message]
    let initialKeys: [KeySeed]
    let steps: [Step]
    let expectations: Expectations
}

private enum FixtureValue: Decodable {
    case object([String: FixtureValue])
    case array([FixtureValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() {
                self = .null
                return
            }
            if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
                return
            }
            if let number = try? container.decode(Double.self) {
                self = .number(number)
                return
            }
            if let string = try? container.decode(String.self) {
                self = .string(string)
                return
            }
            if let array = try? container.decode([FixtureValue].self) {
                self = .array(array)
                return
            }
            if let object = try? container.decode([String: FixtureValue].self) {
                self = .object(object)
                return
            }
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported fixture JSON value")
        )
    }

    var object: [String: FixtureValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    func toJSONValue() -> JSONValue {
        switch self {
        case .object(let object):
            return .object(object.mapValues { $0.toJSONValue() })
        case .array(let array):
            return .array(array.map { $0.toJSONValue() })
        case .string(let string):
            return .string(string)
        case .number(let number):
            return .number(number)
        case .bool(let bool):
            return .bool(bool)
        case .null:
            return .null
        }
    }
}
