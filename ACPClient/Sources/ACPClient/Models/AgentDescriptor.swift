import Foundation

public struct AgentDescriptor: Codable, Hashable {
    public var id: String
    public var displayName: String?
    public var metadata: [String: String]

    public init(id: String, displayName: String? = nil, metadata: [String: String] = [:]) {
        self.id = id
        self.displayName = displayName
        self.metadata = metadata
    }
}