import Foundation
import ACPClient

actor CodexSessionLogger {

    // MARK: - Log Level

    enum LogLevel: Int, Comparable {
        case standard = 0
        case verbose = 1

        static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct Entry: Encodable {
        let ts: String
        let type: String
        let sessionId: String?
        let turnId: String?
        let itemId: String?
        let direction: String?
        let method: String?
        let message: String?
        let title: String?
        let kind: String?
        let status: String?
        let output: String?
        let path: String?
        let changeType: String?
        let diff: String?
        let command: String?
        let cwd: String?
        let endpoint: String?
    }

    /// Extended entry for diagnostic events (connection, merge, snapshot, render).
    struct DiagnosticEntry: Encodable {
        let ts: String
        let type: String
        let sessionId: String?
        let event: String?
        let source: String?
        let detail: String?
        let endpoint: String?
        let stats: DiagnosticStats?
        let messages: [MessageSnapshot]?
    }

    struct DiagnosticStats: Encodable {
        let reused: Int?
        let inserted: Int?
        let updated: Int?
        let unchanged: Int?
        let resumedTurns: Int?
        let resumedItems: Int?
        let staleDetected: Bool?
        let preferLocalRichness: Bool?
        let carryForwardUnmatched: Bool?
        let localToolCalls: Int?
        let resumedToolCalls: Int?
    }

    struct MessageSnapshot: Encodable {
        let index: Int
        let role: String
        let isStreaming: Bool
        let segmentCount: Int
        let segmentKinds: String
        let toolCallCount: Int
        let contentPreview: String
        let messageId: String
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated let logDirectoryURL: URL
    private let maxFiles: Int
    private(set) var logLevel: LogLevel
    private var currentSessionId: String?
    private var currentFileURL: URL?
    private var fileHandle: FileHandle?

    init(maxFiles: Int = 5, logLevel: LogLevel = .verbose) {
        self.maxFiles = max(maxFiles, 10)
        self.logLevel = logLevel
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        logDirectoryURL = base
            .appendingPathComponent("Agmente", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
    }

    func startSession(sessionId: String, endpoint: String, cwd: String?) -> URL? {
        if currentSessionId == sessionId, fileHandle != nil {
            return currentFileURL
        }
        endCurrentSession()

        ensureDirectoryExists()
        pruneOldLogs()

        let url = logFileURL(for: sessionId)
        let didCreate = ensureFileExists(at: url)
        fileHandle = try? FileHandle(forWritingTo: url)
        currentSessionId = sessionId
        currentFileURL = url

        if didCreate {
            write(Entry(
                ts: timestampString(),
                type: "session_start",
                sessionId: sessionId,
                turnId: nil,
                itemId: nil,
                direction: nil,
                method: nil,
                message: nil,
                title: nil,
                kind: nil,
                status: nil,
                output: nil,
                path: nil,
                changeType: nil,
                diff: nil,
                command: nil,
                cwd: cwd,
                endpoint: endpoint
            ))
        }

        // Mark each explicit session open while reusing the same per-session file.
        write(Entry(
            ts: timestampString(),
            type: "session_open",
            sessionId: sessionId,
            turnId: nil,
            itemId: nil,
            direction: nil,
            method: nil,
            message: nil,
            title: nil,
            kind: nil,
            status: nil,
            output: nil,
            path: nil,
            changeType: nil,
            diff: nil,
            command: nil,
            cwd: cwd,
            endpoint: endpoint
        ))

        return url
    }

    func endSession() {
        endCurrentSession()
    }

    func logWire(direction: String, method: String?, message: String, sessionId: String?) {
        write(Entry(
            ts: timestampString(),
            type: "wire",
            sessionId: sessionId,
            turnId: nil,
            itemId: nil,
            direction: direction,
            method: method,
            message: message,
            title: nil,
            kind: nil,
            status: nil,
            output: nil,
            path: nil,
            changeType: nil,
            diff: nil,
            command: nil,
            cwd: nil,
            endpoint: nil
        ))
    }

    func logTurnEvent(type: String, sessionId: String?, turnId: String?) {
        write(Entry(
            ts: timestampString(),
            type: type,
            sessionId: sessionId,
            turnId: turnId,
            itemId: nil,
            direction: nil,
            method: nil,
            message: nil,
            title: nil,
            kind: nil,
            status: nil,
            output: nil,
            path: nil,
            changeType: nil,
            diff: nil,
            command: nil,
            cwd: nil,
            endpoint: nil
        ))
    }

    func logReasoning(sessionId: String?, turnId: String?, itemId: String?, text: String) {
        write(Entry(
            ts: timestampString(),
            type: "reasoning",
            sessionId: sessionId,
            turnId: turnId,
            itemId: itemId,
            direction: nil,
            method: nil,
            message: text,
            title: nil,
            kind: nil,
            status: nil,
            output: nil,
            path: nil,
            changeType: nil,
            diff: nil,
            command: nil,
            cwd: nil,
            endpoint: nil
        ))
    }

    func logToolCall(
        sessionId: String?,
        turnId: String?,
        itemId: String?,
        title: String,
        kind: String?,
        status: String?,
        output: String?
    ) {
        write(Entry(
            ts: timestampString(),
            type: "tool_call",
            sessionId: sessionId,
            turnId: turnId,
            itemId: itemId,
            direction: nil,
            method: nil,
            message: nil,
            title: title,
            kind: kind,
            status: status,
            output: output,
            path: nil,
            changeType: nil,
            diff: nil,
            command: nil,
            cwd: nil,
            endpoint: nil
        ))
    }

    func logFileChange(
        sessionId: String?,
        turnId: String?,
        itemId: String?,
        path: String?,
        changeType: String?,
        diff: String?
    ) {
        write(Entry(
            ts: timestampString(),
            type: "file_change",
            sessionId: sessionId,
            turnId: turnId,
            itemId: itemId,
            direction: nil,
            method: nil,
            message: nil,
            title: nil,
            kind: nil,
            status: nil,
            output: nil,
            path: path,
            changeType: changeType,
            diff: diff,
            command: nil,
            cwd: nil,
            endpoint: nil
        ))
    }

    func logCommandExecution(
        sessionId: String?,
        turnId: String?,
        itemId: String?,
        command: String?,
        output: String?
    ) {
        write(Entry(
            ts: timestampString(),
            type: "command_execution",
            sessionId: sessionId,
            turnId: turnId,
            itemId: itemId,
            direction: nil,
            method: nil,
            message: nil,
            title: nil,
            kind: nil,
            status: nil,
            output: output,
            path: nil,
            changeType: nil,
            diff: nil,
            command: command,
            cwd: nil,
            endpoint: nil
        ))
    }

    // MARK: - Diagnostic Logging (Connection / Merge / Snapshot / Render)

    /// Log a connection lifecycle event.
    func logConnectionEvent(
        event: String,
        sessionId: String?,
        endpoint: String?,
        detail: String? = nil
    ) {
        writeDiagnostic(DiagnosticEntry(
            ts: timestampString(),
            type: "connection",
            sessionId: sessionId,
            event: event,
            source: nil,
            detail: detail,
            endpoint: endpoint,
            stats: nil,
            messages: nil
        ))
    }

    /// Log the outcome of a merge operation after reconnect/resume.
    func logMergeOutcome(
        sessionId: String?,
        source: String,
        reused: Int,
        inserted: Int,
        updated: Int,
        unchanged: Int,
        resumedTurns: Int,
        resumedItems: Int,
        staleDetected: Bool,
        preferLocalRichness: Bool,
        carryForwardUnmatched: Bool,
        localToolCalls: Int,
        resumedToolCalls: Int,
        detail: String? = nil
    ) {
        writeDiagnostic(DiagnosticEntry(
            ts: timestampString(),
            type: "merge_outcome",
            sessionId: sessionId,
            event: nil,
            source: source,
            detail: detail,
            endpoint: nil,
            stats: DiagnosticStats(
                reused: reused,
                inserted: inserted,
                updated: updated,
                unchanged: unchanged,
                resumedTurns: resumedTurns,
                resumedItems: resumedItems,
                staleDetected: staleDetected,
                preferLocalRichness: preferLocalRichness,
                carryForwardUnmatched: carryForwardUnmatched,
                localToolCalls: localToolCalls,
                resumedToolCalls: resumedToolCalls
            ),
            messages: nil
        ))
    }

    /// Log a chat message snapshot (pre/post merge). Verbose-level only.
    func logChatSnapshot(
        sessionId: String?,
        label: String,
        messages: [MessageSnapshot]
    ) {
        guard logLevel >= .verbose else { return }
        writeDiagnostic(DiagnosticEntry(
            ts: timestampString(),
            type: "chat_snapshot",
            sessionId: sessionId,
            event: label,
            source: nil,
            detail: nil,
            endpoint: nil,
            stats: nil,
            messages: messages
        ))
    }

    /// Log a UI rendering decision (thought grouping, carry-forward insertion). Verbose-level only.
    func logRenderDecision(
        sessionId: String?,
        event: String,
        detail: String
    ) {
        guard logLevel >= .verbose else { return }
        writeDiagnostic(DiagnosticEntry(
            ts: timestampString(),
            type: "render_decision",
            sessionId: sessionId,
            event: event,
            source: nil,
            detail: detail,
            endpoint: nil,
            stats: nil,
            messages: nil
        ))
    }

    func setLogLevel(_ level: LogLevel) {
        logLevel = level
    }

    /// Delete all JSONL log files and close the current session file handle.
    func deleteAllLogs() {
        closeFile()
        currentSessionId = nil
        currentFileURL = nil

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.pathExtension == "jsonl" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Log File Collection (for export)

    /// Returns URLs of all JSONL log files sorted newest-first.
    nonisolated func collectLogFileURLs(sessionId: String? = nil) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDirectoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let allLogFiles = files.filter {
            $0.lastPathComponent.hasPrefix("codex-session-") && $0.pathExtension == "jsonl"
        }
        let logFiles: [URL]
        if let sessionId, !sessionId.isEmpty {
            let sanitized = sanitizeFilename(sessionId)
            let exactFilename = "codex-session-\(sanitized).jsonl"
            let legacyPrefix = "codex-session-\(sanitized)-"
            logFiles = allLogFiles.filter { url in
                let name = url.lastPathComponent
                return name == exactFilename || name.hasPrefix(legacyPrefix)
            }
        } else {
            logFiles = allLogFiles
        }

        return logFiles.sorted { lhs, rhs in
            let lhsValues = try? lhs.resourceValues(forKeys: Set(keys))
            let rhsValues = try? rhs.resourceValues(forKeys: Set(keys))
            let lhsDate = lhsValues?.contentModificationDate ?? lhsValues?.creationDate ?? .distantPast
            let rhsDate = rhsValues?.contentModificationDate ?? rhsValues?.creationDate ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    private func endCurrentSession() {
        guard let sessionId = currentSessionId else {
            closeFile()
            return
        }
        write(Entry(
            ts: timestampString(),
            type: "session_end",
            sessionId: sessionId,
            turnId: nil,
            itemId: nil,
            direction: nil,
            method: nil,
            message: nil,
            title: nil,
            kind: nil,
            status: nil,
            output: nil,
            path: nil,
            changeType: nil,
            diff: nil,
            command: nil,
            cwd: nil,
            endpoint: nil
        ))
        closeFile()
        currentSessionId = nil
        currentFileURL = nil
    }

    private func closeFile() {
        guard let fileHandle else { return }
        try? fileHandle.close()
        self.fileHandle = nil
    }

    private func write(_ entry: Entry) {
        guard prepareHandleIfNeeded(for: entry.sessionId) else { return }
        guard let fileHandle else { return }
        guard let data = try? encoder.encode(entry) else { return }
        var line = data
        line.append(0x0A)
        do {
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: line)
        } catch {
            // Best-effort logging.
        }
    }

    private func writeDiagnostic(_ entry: DiagnosticEntry) {
        guard prepareHandleIfNeeded(for: entry.sessionId) else { return }
        guard let fileHandle else { return }
        guard let data = try? encoder.encode(entry) else { return }
        var line = data
        line.append(0x0A)
        do {
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: line)
        } catch {
            // Best-effort logging.
        }
    }

    @discardableResult
    private func prepareHandleIfNeeded(for sessionId: String?) -> Bool {
        guard let sessionId, !sessionId.isEmpty else {
            return fileHandle != nil
        }

        if currentSessionId == sessionId, fileHandle != nil {
            return true
        }

        closeFile()
        ensureDirectoryExists()
        pruneOldLogs()

        let url = logFileURL(for: sessionId)
        _ = ensureFileExists(at: url)
        fileHandle = try? FileHandle(forWritingTo: url)
        currentSessionId = sessionId
        currentFileURL = url
        return fileHandle != nil
    }

    private func ensureDirectoryExists() {
        if !FileManager.default.fileExists(atPath: logDirectoryURL.path) {
            try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
        }
    }

    private func logFileURL(for sessionId: String) -> URL {
        let sanitizedId = sanitizeFilename(sessionId)
        return logDirectoryURL.appendingPathComponent("codex-session-\(sanitizedId).jsonl")
    }

    @discardableResult
    private func ensureFileExists(at url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            return false
        }
        return FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    private func pruneOldLogs() {
        guard maxFiles > 0 else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDirectoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }
        let logFiles = files.filter { $0.lastPathComponent.hasPrefix("codex-session-") && $0.pathExtension == "jsonl" }
        if logFiles.count <= maxFiles { return }

        let sorted = logFiles.sorted { lhs, rhs in
            let lhsValues = try? lhs.resourceValues(forKeys: Set(keys))
            let rhsValues = try? rhs.resourceValues(forKeys: Set(keys))
            let lhsDate = lhsValues?.contentModificationDate ?? lhsValues?.creationDate ?? .distantPast
            let rhsDate = rhsValues?.contentModificationDate ?? rhsValues?.creationDate ?? .distantPast
            return lhsDate > rhsDate
        }

        for file in sorted.dropFirst(maxFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func timestampString() -> String {
        isoFormatter.string(from: Date())
    }

    nonisolated private func sanitizeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let sanitized = String(scalars)
        return sanitized.isEmpty ? "session" : sanitized
    }
}
