import Foundation
import ACP

public enum ACPSessionListParser {
    public static func parse(
        sessions: [ACP.Value],
        transformCwd: (String?) -> String? = { $0 }
    ) -> [SessionSummary] {
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso8601FormatterNoFraction = ISO8601DateFormatter()
        iso8601FormatterNoFraction.formatOptions = [.withInternetDateTime]

        let parsedSummaries: [SessionSummary] = sessions.compactMap { element in
            if let obj = element.objectValue {
                let id = obj["sessionId"]?.stringValue
                    ?? obj["session"]?.stringValue
                    ?? obj["id"]?.stringValue
                guard let id, !id.isEmpty else { return nil }

                let rawTitle = obj["title"]?.stringValue
                let rawPrompt = obj["prompt"]?.stringValue
                let title = rawTitle.flatMap { $0.isEmpty ? nil : $0 }
                    ?? rawPrompt.flatMap { $0.isEmpty ? nil : $0 }

                let cwd = transformCwd(obj["cwd"]?.stringValue ?? obj["workingDirectory"]?.stringValue)
                let updatedAt = parseTimestamp(
                    obj: obj,
                    iso8601Formatter: iso8601Formatter,
                    iso8601FormatterNoFraction: iso8601FormatterNoFraction
                )

                return SessionSummary(id: id, title: title, cwd: cwd, updatedAt: updatedAt)
            }

            return nil
        }

        return parsedSummaries.sorted { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (lhsDate?, rhsDate?):
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.id < rhs.id
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.id < rhs.id
            }
        }
    }

    private static func parseTimestamp(
        obj: [String: ACP.Value],
        iso8601Formatter: ISO8601DateFormatter,
        iso8601FormatterNoFraction: ISO8601DateFormatter
    ) -> Date? {
        if let mtime = obj["mtime"]?.numberValue {
            return Date(timeIntervalSince1970: normalizeUnixTimestampToSeconds(mtime))
        }
        if let updatedAtNumber = obj["updatedAt"]?.numberValue {
            return Date(timeIntervalSince1970: normalizeUnixTimestampToSeconds(updatedAtNumber))
        }
        if let updatedAtString = obj["updatedAt"]?.stringValue {
            if let numeric = Double(updatedAtString) {
                return Date(timeIntervalSince1970: normalizeUnixTimestampToSeconds(numeric))
            }
            return iso8601Formatter.date(from: updatedAtString)
                ?? iso8601FormatterNoFraction.date(from: updatedAtString)
        }
        if let startTimeNumber = obj["startTime"]?.numberValue {
            return Date(timeIntervalSince1970: normalizeUnixTimestampToSeconds(startTimeNumber))
        }
        if let startTimeString = obj["startTime"]?.stringValue {
            if let numeric = Double(startTimeString) {
                return Date(timeIntervalSince1970: normalizeUnixTimestampToSeconds(numeric))
            }
            return iso8601Formatter.date(from: startTimeString)
                ?? iso8601FormatterNoFraction.date(from: startTimeString)
        }
        return nil
    }

    private static func normalizeUnixTimestampToSeconds(_ raw: Double) -> TimeInterval {
        if raw >= 1e17 {
            return raw / 1_000_000_000.0
        }
        if raw >= 1e14 {
            return raw / 1_000_000.0
        }
        if raw >= 1e11 {
            return raw / 1_000.0
        }
        return raw
    }
}