import SwiftUI

// MARK: - Shared Chat Components

enum ChatScrollCoordinateSpace {
    static let name = "chatScroll"
}

struct ChatContentMetrics: Equatable {
    let height: CGFloat
    let minY: CGFloat
}

private struct ChatScrollViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ChatContentMetricsKey: PreferenceKey {
    static var defaultValue: ChatContentMetrics = .init(height: 0, minY: 0)

    static func reduce(value: inout ChatContentMetrics, nextValue: () -> ChatContentMetrics) {
        value = nextValue()
    }
}

struct ChatScrollViewHeightReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: ChatScrollViewHeightKey.self, value: proxy.size.height)
        }
    }
}

struct ChatContentMetricsReader: View {
    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(ChatScrollCoordinateSpace.name))
            Color.clear
                .preference(
                    key: ChatContentMetricsKey.self,
                    value: ChatContentMetrics(height: frame.height, minY: frame.minY)
                )
        }
    }
}

extension View {
    func onChatScrollViewHeightChange(_ handler: @escaping (CGFloat) -> Void) -> some View {
        onPreferenceChange(ChatScrollViewHeightKey.self, perform: handler)
    }

    func onChatContentMetricsChange(_ handler: @escaping (ChatContentMetrics) -> Void) -> some View {
        onPreferenceChange(ChatContentMetricsKey.self, perform: handler)
    }

    @ViewBuilder
    func applyScrollTargetLayoutIfAvailable() -> some View {
        if #available(iOS 17.0, *) {
            scrollTargetLayout()
        } else {
            self
        }
    }

    @ViewBuilder
    func applyScrollPositionIfAvailable(id: Binding<UUID?>) -> some View {
        if #available(iOS 17.0, *) {
            scrollPosition(id: id, anchor: .bottom)
        } else {
            self
        }
    }
}

extension AssistantSegment {
    func toolCallSummaryText() -> String {
        guard kind == .toolCall else { return text }
        var header = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if header.isEmpty {
            header = (toolCall?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !header.isEmpty else { return "" }
        if let status = toolCall?.status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
            header += " (\(status))"
        }
        var parts = ["Tool call: \(header)"]
        if let output = toolCall?.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            parts.append("Result:\n\(output)")
        }
        return parts.joined(separator: "\n")
    }
}

enum ThoughtBlock: Identifiable {
    case thought(AssistantSegment)
    case toolCall(AssistantSegment)

    var id: UUID {
        switch self {
        case .thought(let segment), .toolCall(let segment):
            return segment.id
        }
    }
}

struct ThoughtGroup: Identifiable {
    let id: UUID
    let blocks: [ThoughtBlock]

    var combinedText: String {
        var parts: [String] = []
        for block in blocks {
            switch block {
            case .thought(let segment):
                let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                }
            case .toolCall(let segment):
                let toolText = segment.toolCallSummaryText()
                if !toolText.isEmpty {
                    parts.append(toolText)
                }
            }
        }
        return parts.joined(separator: "\n\n")
    }
}

enum DisplaySegment: Identifiable {
    case message(AssistantSegment)
    case toolCall(AssistantSegment)
    case thoughtGroup(ThoughtGroup)

    var id: UUID {
        switch self {
        case .message(let segment), .toolCall(let segment):
            return segment.id
        case .thoughtGroup(let group):
            return group.id
        }
    }
}

extension Array where Element == AssistantSegment {
    func groupedThoughtSegments() -> [DisplaySegment] {
        var grouped: [DisplaySegment] = []
        var currentBlocks: [ThoughtBlock] = []
        var currentGroupId: UUID?

        func flushGroup() {
            if !currentBlocks.isEmpty {
                let groupId = currentGroupId ?? UUID()
                grouped.append(.thoughtGroup(ThoughtGroup(id: groupId, blocks: currentBlocks)))
                currentBlocks.removeAll()
                currentGroupId = nil
            }
        }

        for segment in self {
            switch segment.kind {
            case .thought:
                if currentBlocks.isEmpty {
                    currentGroupId = segment.id
                }
                currentBlocks.append(.thought(segment))
            case .toolCall:
                if !currentBlocks.isEmpty {
                    currentBlocks.append(.toolCall(segment))
                } else {
                    grouped.append(.toolCall(segment))
                }
            case .message:
                flushGroup()
                grouped.append(.message(segment))
            }
        }

        flushGroup()
        return grouped
    }
}

/// Renders basic Markdown into SwiftUI Text for chat content.
/// Used by both SessionDetailView and CodexSessionDetailView.
struct MarkdownText: View {
    let content: String
    var font: Font = .callout

    var body: some View {
        let unescaped = content
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if unescaped.isEmpty {
            EmptyView()
        } else {
            let (displayText, _) = truncateIfNeeded(unescaped, maxLines: 400, maxChars: 20_000)
            let normalizedContent = displayText
                .replacingOccurrences(of: "\r\n", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    let trimmedEnd = line.last == " " ? String(line) : String(line) + "  "
                    return trimmedEnd
                }
                .joined(separator: "\n")

            let shouldRenderPlainText = unescaped.count > 20_000
            if !shouldRenderPlainText,
               let attributed = try? AttributedString(markdown: normalizedContent, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                let renderedText = String(attributed.characters)
                if renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(verbatim: displayText)
                        .font(font)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(attributed)
                        .font(font)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(verbatim: displayText)
                    .font(font)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func truncateIfNeeded(_ text: String, maxLines: Int, maxChars: Int) -> (String, Bool) {
        var lineCount = 1
        var charCount = 0
        var index = text.startIndex

        while index < text.endIndex {
            if charCount >= maxChars {
                let prefix = String(text[..<index])
                return (prefix + "\n\n... (message truncated)", true)
            }
            if text[index] == "\n" {
                lineCount += 1
                if lineCount > maxLines {
                    let prefix = String(text[..<index])
                    return (prefix + "\n\n... (message truncated)", true)
                }
            }
            charCount += 1
            index = text.index(after: index)
        }

        return (text, false)
    }
}

extension String {
    func truncatedToolOutput(maxLines: Int = 6, maxChars: Int = 1_200) -> String {
        guard !isEmpty else { return self }
        var lineCount = 1
        var charCount = 0
        var index = startIndex

        while index < endIndex {
            if charCount >= maxChars {
                let prefix = String(self[..<index])
                let remaining = max(0, count - prefix.count)
                return prefix + "\n\n… (\(remaining) more characters)"
            }
            if self[index] == "\n" {
                lineCount += 1
                if lineCount > maxLines {
                    let prefix = String(self[..<index])
                    let remaining = max(0, count - prefix.count)
                    return prefix + "\n\n… (\(remaining) more characters)"
                }
            }
            charCount += 1
            index = self.index(after: index)
        }

        return self
    }

    func truncatedLabel(maxChars: Int = 80) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        return String(trimmed.prefix(maxChars)) + "…"
    }
}

/// A loading indicator bubble shown while waiting for assistant response.
struct ShimmeringBubble: View {
    let text: String
    
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

/// A system message bubble with info icon.
struct SystemBubble: View {
    let content: String
    
    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(content)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.systemGray5))
            .clipShape(Capsule())
            Spacer()
        }
    }
}

/// An error message bubble with warning icon.
struct ErrorBubble: View {
    let content: String
    
    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Text(content)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.1))
            .clipShape(Capsule())
            Spacer()
        }
    }
}

/// A user message bubble with optional images.
struct UserBubble: View {
    let content: String
    let images: [ChatImageData]
    
    init(content: String, images: [ChatImageData] = []) {
        self.content = content
        self.images = images
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 50)
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(images) { imageData in
                            Image(uiImage: imageData.thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                                )
                        }
                    }
                }
                
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MarkdownText(content: content)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(.horizontal, 2)
    }
}

/// An assistant message text bubble (for simple text content).
struct AssistantTextBubble: View {
    let content: String
    
    var body: some View {
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MarkdownText(content: content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Placeholder Views

struct SessionPlaceholderView: View {
    var onAddServer: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            PixelBot()
            Text(onAddServer == nil ? "Create a session to start chatting." : "Add or pick a server to start chatting.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let onAddServer {
                Button(action: onAddServer) {
                    Label("Add Server", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("emptyStateAddServerButton")
            }
            
            Link(destination: URL(string: "https://agmente.halliharp.com/docs/guides/local-agent")!) {
                Label("Setup guide", systemImage: "book")
                    .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct SessionCard: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let isDimmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body)
                .foregroundStyle(isDimmed ? .secondary : .primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
    }
}

struct PixelBot: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Agmente")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text("/aɡˈmen.te/")
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
