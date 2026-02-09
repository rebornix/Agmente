import CoreData
import Foundation
import ACPClient

/// Provides Core Data persistence for servers and sessions.
/// Sessions are stored locally so they can be restored via `session/load` or reattached via `session/resume` after app restart (depending on agent support).
final class SessionStorage {
    static let shared = SessionStorage(container: PersistenceController.shared.container)
    
    private let container: NSPersistentContainer
    private var viewContext: NSManagedObjectContext { container.viewContext }
    
    init(container: NSPersistentContainer) {
        self.container = container
    }

    static func inMemory() -> SessionStorage {
        let controller = PersistenceController(inMemory: true)
        return SessionStorage(container: controller.container)
    }
    
    // MARK: - Server Operations
    
    /// Fetch all stored servers.
    func fetchServers() -> [ACPServerConfiguration] {
        let request = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \StoredServer.name, ascending: true)]
        
        do {
            let results = try viewContext.fetch(request)
            return results.map { stored in
                let workingDirectory = Self.normalizedWorkingDirectory(stored.workingDirectory ?? "") ?? ""
                let serverType = ServerType(rawValue: stored.serverType ?? "acp") ?? .acp
                return ACPServerConfiguration(
                    id: stored.id ?? UUID(),
                    name: stored.name ?? "",
                    scheme: stored.scheme ?? "ws",
                    host: stored.host ?? "",
                    token: stored.token ?? "",
                    cfAccessClientId: stored.cfAccessClientId ?? "",
                    cfAccessClientSecret: stored.cfAccessClientSecret ?? "",
                    workingDirectory: workingDirectory,
                    serverType: serverType
                )
            }
        } catch {
            return []
        }
    }
    
    /// Save or update a server configuration.
    func saveServer(_ server: ACPServerConfiguration) {
        let request = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        request.predicate = NSPredicate(format: "id == %@", server.id as CVarArg)
        
        do {
            let results = try viewContext.fetch(request)
            let stored: StoredServer
            if let existing = results.first {
                stored = existing
            } else {
                stored = StoredServer(context: viewContext)
                stored.id = server.id
            }
            
            stored.name = server.name
            stored.scheme = server.scheme
            stored.host = server.host
            stored.token = server.token
            stored.cfAccessClientId = server.cfAccessClientId
            stored.cfAccessClientSecret = server.cfAccessClientSecret
            stored.serverType = server.serverType.rawValue
            let sanitizedWorkingDirectory = Self.normalizedWorkingDirectory(server.workingDirectory)
            stored.workingDirectory = sanitizedWorkingDirectory

            // Keep the working directory history in sync with the server's configured default.
            var usedDirectories = (stored.usedWorkingDirectories as? [String]) ?? []
            if let sanitizedWorkingDirectory, !usedDirectories.contains(sanitizedWorkingDirectory) {
                usedDirectories.insert(sanitizedWorkingDirectory, at: 0)
            }
            stored.usedWorkingDirectories = usedDirectories as NSArray

            try viewContext.save()
        } catch {
        }
    }

    /// Trims whitespace from a working directory. Returns `nil` when the result is empty so we don't
    /// overwrite stored values with a fabricated default.
    private static func normalizedWorkingDirectory(_ workingDirectory: String) -> String? {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    
    /// Delete a server and all its associated sessions.
    func deleteServer(id: UUID) {
        let request = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        do {
            let results = try viewContext.fetch(request)
            if let stored = results.first {
                viewContext.delete(stored)
                try viewContext.save()
            }
        } catch {
        }
    }
    
    // MARK: - Used Working Directories
    
    /// Fetch the list of working directories that have been used with this server.
    func fetchUsedWorkingDirectories(forServerId serverId: UUID) -> [String] {
        let request = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        request.predicate = NSPredicate(format: "id == %@", serverId as CVarArg)
        
        do {
            if let stored = try viewContext.fetch(request).first,
               let directories = stored.usedWorkingDirectories as? [String] {
                return directories
            }
        } catch {
        }
        return []
    }
    
    /// Add a working directory to the list of used directories for a server.
    /// Returns true if the directory was newly added, false if it was already in the list.
    @discardableResult
    func addUsedWorkingDirectory(_ directory: String, forServerId serverId: UUID) -> Bool {
        let request = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        request.predicate = NSPredicate(format: "id == %@", serverId as CVarArg)

        do {
            if let stored = try viewContext.fetch(request).first {
                var directories = (stored.usedWorkingDirectories as? [String]) ?? []
                if !directories.contains(directory) {
                    directories.append(directory)
                    stored.usedWorkingDirectories = directories as NSArray
                    try viewContext.save()
                    return true
                }
            }
        } catch {
        }
        return false
    }
    
    // MARK: - Session Operations
    
    /// Fetch all sessions for a given server.
    func fetchSessions(forServerId serverId: UUID) -> [StoredSessionInfo] {
        let request = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        request.predicate = NSPredicate(format: "server.id == %@", serverId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \StoredSession.updatedAt, ascending: false)]
        
        do {
            let results = try viewContext.fetch(request)
            return results.map { stored in
                StoredSessionInfo(
                    sessionId: stored.sessionId ?? "",
                    title: stored.title,
                    cwd: stored.cwd,
                    updatedAt: stored.updatedAt
                )
            }
        } catch {
            return []
        }
    }
    
    /// Save or update a session for a given server.
    func saveSession(_ session: StoredSessionInfo, forServerId serverId: UUID) {
        // First, find the server
        let serverRequest = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        serverRequest.predicate = NSPredicate(format: "id == %@", serverId as CVarArg)
        
        do {
            guard let server = try viewContext.fetch(serverRequest).first else {
                return
            }
            
            // Check if session already exists
            let sessionRequest = NSFetchRequest<StoredSession>(entityName: "StoredSession")
            sessionRequest.predicate = NSPredicate(
                format: "sessionId == %@ AND server.id == %@",
                session.sessionId,
                serverId as CVarArg
            )
            
            let results = try viewContext.fetch(sessionRequest)
            let stored: StoredSession
            let isNew: Bool
            if let existing = results.first {
                stored = existing
                isNew = false
            } else {
                stored = StoredSession(context: viewContext)
                stored.sessionId = session.sessionId
                stored.server = server
                isNew = true
            }
            
            // Never overwrite existing fields with nil, since callers often pass nil
            // to indicate "unknown" (e.g., before the first user message sets a title).
            if let title = session.title {
                stored.title = title
            }
            if let cwd = session.cwd {
                stored.cwd = cwd
            }
            if let updatedAt = session.updatedAt {
                stored.updatedAt = updatedAt
            } else if isNew {
                // Avoid forcing "today" grouping for sessions with unknown timestamps.
                stored.updatedAt = nil
            }
            
            try viewContext.save()
        } catch {
        }
    }
    
    /// Update fields of an existing session.
    /// - Parameters:
    ///   - title: When non-nil, updates the stored title.
    ///   - touchUpdatedAt: When true, sets `updatedAt` to `Date()` (local activity timestamp).
    func updateSession(sessionId: String, forServerId serverId: UUID, title: String?, touchUpdatedAt: Bool = true) {
        let request = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        request.predicate = NSPredicate(
            format: "sessionId == %@ AND server.id == %@",
            sessionId,
            serverId as CVarArg
        )
        
        do {
            if let stored = try viewContext.fetch(request).first {
                if let title = title {
                    stored.title = title
                }
                if touchUpdatedAt {
                    stored.updatedAt = Date()
                }
                try viewContext.save()
            }
        } catch {
        }
    }
    
    /// Delete a session.
    func deleteSession(sessionId: String, forServerId serverId: UUID) {
        let request = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        request.predicate = NSPredicate(
            format: "sessionId == %@ AND server.id == %@",
            sessionId,
            serverId as CVarArg
        )
        
        do {
            if let stored = try viewContext.fetch(request).first {
                viewContext.delete(stored)
                try viewContext.save()
            }
        } catch {
        }
    }
    
    /// Delete all sessions for a server.
    func deleteAllSessions(forServerId serverId: UUID) {
        let request = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        request.predicate = NSPredicate(format: "server.id == %@", serverId as CVarArg)
        
        do {
            let results = try viewContext.fetch(request)
            for session in results {
                viewContext.delete(session)
            }
            try viewContext.save()
        } catch {
        }
    }

    /// Remove any stored sessions for this server that are not in `keeping`.
    /// Intended to keep Core Data in sync with agents that support `session/list`.
    @discardableResult
    func pruneSessions(forServerId serverId: UUID, keeping sessionIds: Set<String>) -> Int {
        let request = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        request.predicate = NSPredicate(format: "server.id == %@", serverId as CVarArg)

        do {
            let results = try viewContext.fetch(request)
            var deleted = 0
            for session in results {
                let id = session.sessionId ?? ""
                if !sessionIds.contains(id) {
                    viewContext.delete(session)
                    deleted += 1
                }
            }
            if viewContext.hasChanges {
                try viewContext.save()
            }
            return deleted
        } catch {
            return 0
        }
    }
    
    // MARK: - Message Operations
    
    /// Save messages for a session. Replaces all existing messages.
    func saveMessages(_ messages: [StoredMessageInfo], forSessionId sessionId: String, serverId: UUID) {
        // First find the session
        let sessionRequest = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        sessionRequest.predicate = NSPredicate(
            format: "sessionId == %@ AND server.id == %@",
            sessionId,
            serverId as CVarArg
        )
        
        do {
            guard let session = try viewContext.fetch(sessionRequest).first else {
                return
            }
            
            // Delete existing messages
            if let existingMessages = session.messages as? Set<StoredMessage> {
                for message in existingMessages {
                    viewContext.delete(message)
                }
            }
            
            // Add new messages
            for (index, messageInfo) in messages.enumerated() {
                let stored = StoredMessage(context: viewContext)
                stored.messageId = messageInfo.messageId
                stored.role = messageInfo.role
                stored.content = messageInfo.content
                stored.createdAt = messageInfo.createdAt
                stored.orderIndex = Int32(index)
                stored.segmentsData = messageInfo.segmentsData
                stored.session = session
            }
            
            try viewContext.save()
        } catch {
        }
    }
    
    /// Fetch all messages for a session, ordered by creation.
    func fetchMessages(forSessionId sessionId: String, serverId: UUID) -> [StoredMessageInfo] {
        let sessionRequest = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        sessionRequest.predicate = NSPredicate(
            format: "sessionId == %@ AND server.id == %@",
            sessionId,
            serverId as CVarArg
        )
        
        do {
            guard let session = try viewContext.fetch(sessionRequest).first else {
                return []
            }
            
            guard let messagesSet = session.messages as? Set<StoredMessage> else {
                return []
            }
            
            // Sort by orderIndex
            let sortedMessages = messagesSet.sorted { ($0.orderIndex) < ($1.orderIndex) }
            
            return sortedMessages.map { stored in
                StoredMessageInfo(
                    messageId: stored.messageId ?? UUID(),
                    role: stored.role ?? "user",
                    content: stored.content ?? "",
                    createdAt: stored.createdAt ?? Date(),
                    segmentsData: stored.segmentsData
                )
            }
        } catch {
            return []
        }
    }
    
    /// Delete all messages for a session.
    func deleteMessages(forSessionId sessionId: String, serverId: UUID) {
        let sessionRequest = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        sessionRequest.predicate = NSPredicate(
            format: "sessionId == %@ AND server.id == %@",
            sessionId,
            serverId as CVarArg
        )
        
        do {
            guard let session = try viewContext.fetch(sessionRequest).first else {
                return
            }
            
            if let existingMessages = session.messages as? Set<StoredMessage> {
                for message in existingMessages {
                    viewContext.delete(message)
                }
            }
            
            try viewContext.save()
        } catch {
        }
    }
}

// MARK: - Data Types

/// A lightweight struct representing session info stored in Core Data.
/// Maps to the `StoredSession` entity but is easier to work with in Swift code.
struct StoredSessionInfo: Identifiable, Hashable {
    var id: String { sessionId }
    let sessionId: String
    let title: String?
    let cwd: String?
    let updatedAt: Date?
    
    /// Convert to the view model's SessionSummary type.
    func toSessionSummary() -> SessionSummary {
        SessionSummary(id: sessionId, title: title, cwd: cwd, updatedAt: updatedAt)
    }
}

/// A lightweight struct representing message info stored in Core Data.
/// Maps to the `StoredMessage` entity but is easier to work with in Swift code.
struct StoredMessageInfo: Identifiable, Hashable {
    var id: UUID { messageId }
    let messageId: UUID
    let role: String
    let content: String
    let createdAt: Date
    /// Encoded segments data (for assistant messages with tool calls, etc.)
    let segmentsData: Data?
}
