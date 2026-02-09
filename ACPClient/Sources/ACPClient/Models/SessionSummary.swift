import Foundation

public struct SessionSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String?
    public let cwd: String?
    public let updatedAt: Date?

    public init(id: String, title: String?, cwd: String? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
    }
}

public typealias ACPClientSessionSummary = SessionSummary

@available(*, deprecated, message: "Use SessionSummary")
public typealias SessionSummaryItem = SessionSummary