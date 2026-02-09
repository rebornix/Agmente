import SwiftUI

struct FileChangeSummaryItem: Identifiable, Equatable {
    let id: String
    let title: String
    let path: String
    let verb: String?
    let status: String?
    let diff: String?
}

enum FileChangeSummary {
    static func isFileChangeSegment(_ segment: AssistantSegment) -> Bool {
        guard segment.kind == .toolCall else { return false }
        let kind = segment.toolCall?.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !kind.isEmpty {
            let normalized = kind.replacingOccurrences(of: "_", with: "-")
            let tokens = normalized.split(whereSeparator: { $0 == "." || $0 == "/" || $0 == "-" })
            let matchTokens = ["edit", "file", "files", "patch", "diff", "apply", "write"]
            if tokens.contains(where: { matchTokens.contains(String($0)) }) {
                return true
            }
        }

        let title = (segment.toolCall?.title ?? segment.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let prefixes = ["edit:", "create:", "delete:", "rename:", "move:", "add:", "update:"]
        return prefixes.contains { title.hasPrefix($0) }
    }

    static func items(from segments: [AssistantSegment]) -> [FileChangeSummaryItem] {
        var items: [FileChangeSummaryItem] = []
        items.reserveCapacity(segments.count)

        for (index, segment) in segments.enumerated() where isFileChangeSegment(segment) {
            let title = (segment.toolCall?.title ?? segment.text).trimmingCharacters(in: .whitespacesAndNewlines)
            let (verb, path) = parseTitle(title)
            let status = segment.toolCall?.status
            let diff = segment.toolCall?.output?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let diff, !diff.isEmpty else { continue }
            let id = segment.toolCall?.toolCallId ?? "\(path)-\(index)"
            items.append(
                FileChangeSummaryItem(
                    id: id,
                    title: title,
                    path: path,
                    verb: verb,
                    status: status,
                    diff: diff
                )
            )
        }

        return items
    }

    private static func parseTitle(_ title: String) -> (verb: String?, path: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colonIndex = trimmed.firstIndex(of: ":") else {
            let fallback = trimmed.isEmpty ? "Unknown file" : trimmed
            return (nil, fallback)
        }
        let verb = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let pathStart = trimmed.index(after: colonIndex)
        let path = String(trimmed[pathStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath = path.isEmpty ? "Unknown file" : path
        let resolvedVerb = verb.isEmpty ? nil : verb
        return (resolvedVerb, resolvedPath)
    }
}

struct FileChangesSummaryView: View {
    let items: [FileChangeSummaryItem]
    let onUndo: () -> Void
    let onReview: () -> Void

    private var uniqueItems: [FileChangeSummaryItem] {
        var chosen: [String: FileChangeSummaryItem] = [:]
        var order: [String] = []

        for item in items {
            let key = normalizedPathKey(item.path)
            if let existing = chosen[key] {
                chosen[key] = preferredItem(existing, item)
            } else {
                chosen[key] = item
                order.append(key)
            }
        }

        return order.compactMap { chosen[$0] }
    }

    private func normalizedPathKey(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        let separators = CharacterSet(charactersIn: "/\\")
        let parts = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }
        return (parts.last ?? trimmed).lowercased()
    }

    private func preferredItem(_ existing: FileChangeSummaryItem, _ candidate: FileChangeSummaryItem) -> FileChangeSummaryItem {
        let existingPath = existing.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidatePath = candidate.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingHasSeparator = existingPath.contains("/") || existingPath.contains("\\")
        let candidateHasSeparator = candidatePath.contains("/") || candidatePath.contains("\\")

        if existingHasSeparator != candidateHasSeparator {
            return existingHasSeparator ? existing : candidate
        }

        let existingVerb = existing.verb?.lowercased() ?? ""
        let candidateVerb = candidate.verb?.lowercased() ?? ""
        let existingStatus = existing.status?.lowercased() ?? ""
        let candidateStatus = candidate.status?.lowercased() ?? ""
        let existingIsDiff = existingVerb == "diff" || existingStatus == "diff"
        let candidateIsDiff = candidateVerb == "diff" || candidateStatus == "diff"

        if existingIsDiff != candidateIsDiff {
            return existingIsDiff ? candidate : existing
        }

        if existingPath.count != candidatePath.count {
            return existingPath.count >= candidatePath.count ? existing : candidate
        }

        return existing
    }

    private var summaryTitle: String {
        let count = uniqueItems.count
        return "\(count) file" + (count == 1 ? " changed" : "s changed")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(summaryTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button("Undo", action: onUndo)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)

                Button("Review", action: onReview)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
            }

            ForEach(uniqueItems) { item in
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.path)
                            .font(.footnote)
                            .foregroundStyle(.primary)

                        if let verb = item.verb {
                            Text(verb.capitalized)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if let status = item.status, !status.isEmpty {
                            Text(status.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct FileChangesReviewSheet: View {
    let items: [FileChangeSummaryItem]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.path)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            if let verb = item.verb {
                                Text(verb.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let diff = item.diff, !diff.isEmpty {
                                Text(diff)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            } else {
                                Text("No diff provided.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .navigationTitle("File Changes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}