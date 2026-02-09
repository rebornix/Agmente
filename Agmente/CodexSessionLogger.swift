import Foundation
import ACPClient

actor CodexSessionLogger {
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

    private let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private let logDirectoryURL: URL
    private let maxFiles: Int
    private var currentSessionId: String?
    private var currentFileURL: URL?
    private var fileHandle: FileHandle?

    init(maxFiles: Int = 3) {
        self.maxFiles = maxFiles
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

        let sanitizedId = sanitizeFilename(sessionId)
        let timestamp = filenameFormatter.string(from: Date())
        let filename = "codex-session-\(sanitizedId)-\(timestamp).jsonl"
        let url = logDirectoryURL.appendingPathComponent(filename)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        currentSessionId = sessionId
        currentFileURL = url

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

    private func ensureDirectoryExists() {
        if !FileManager.default.fileExists(atPath: logDirectoryURL.path) {
            try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
        }
    }

    private func pruneOldLogs() {
        guard maxFiles > 0 else { return }
        let keys: [URLResourceKey] = [.creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDirectoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }
        let logFiles = files.filter { $0.lastPathComponent.hasPrefix("codex-session-") && $0.pathExtension == "jsonl" }
        if logFiles.count <= maxFiles { return }

        let sorted = logFiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
            return lhsDate > rhsDate
        }

        for file in sorted.dropFirst(maxFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func timestampString() -> String {
        isoFormatter.string(from: Date())
    }

    private func sanitizeFilename(_ value: String) -> String {
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