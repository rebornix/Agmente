import SwiftUI
import UIKit
import ACPClient

/// Session detail view for Codex app-server connections.
/// Mirrors SessionDetailView but uses CodexServerViewModel.
struct CodexSessionDetailView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var serverViewModel: CodexServerViewModel
    @ObservedObject var sessionViewModel: ACPSessionViewModel
    @FocusState private var isTextEditorFocused: Bool
    @State private var textEditorWidth: CGFloat = 0
    @State private var showDeleteSessionConfirm = false
    @State private var expandedThoughts: Set<UUID> = []
    @State private var fileChangesReviewPayload: FileChangesReviewPayload?
    @State private var showUndoUnavailableAlert = false
    @State private var scrollViewHeight: CGFloat = 0
    @State private var isAtBottom = true
    @State private var composerHeight: CGFloat = 0
    @State private var scrollToBottomAction: (() -> Void)?
    @State private var scrollPosition: UUID?

    private struct FileChangesReviewPayload: Identifiable {
        let id = UUID()
        let items: [FileChangeSummaryItem]
    }

    private var textEditorHeight: CGFloat {
        let uiFont = UIFont.preferredFont(forTextStyle: .body)
        let sizingTextView = makeSizingTextView(font: uiFont)
        let baseHeight = uiFont.lineHeight + sizingTextView.textContainerInset.top + sizingTextView.textContainerInset.bottom

        guard textEditorWidth > 0 else {
            return min(110, ceil(baseHeight))
        }

        sizingTextView.text = model.promptText.isEmpty ? " " : model.promptText
        let size = sizingTextView.sizeThatFits(CGSize(width: textEditorWidth, height: .greatestFiniteMagnitude))
        return min(110, ceil(max(baseHeight, size.height)))
    }

    private var selectedCommand: SessionCommand? {
        sessionViewModel.availableCommands.first { $0.name == sessionViewModel.selectedCommandName }
    }

    private var promptPlaceholderText: String {
        if let command = selectedCommand {
            return command.inputHint ?? command.description
        }
        return "Message the agent…"
    }

    private func makeSizingTextView(font: UIFont) -> UITextView {
        let textView = UITextView()
        textView.font = font
        textView.isScrollEnabled = false
        return textView
    }

    var body: some View {
        ZStack {
            Color(.systemGray6)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                chatTranscript
                    .frame(maxHeight: .infinity)

                composer
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { composerHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, newValue in
                                    composerHeight = newValue
                                }
                        }
                    )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if shouldShowScrollToBottomButton {
                Button {
                    if #available(iOS 17.0, *) {
                        if let lastId = sessionViewModel.chatMessages.last?.id {
                            scrollPosition = lastId
                            isAtBottom = true
                        }
                    } else {
                        scrollToBottomAction?()
                        isAtBottom = true
                    }
                } label: {
                    if #available(iOS 26, *) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(12)
                            .glassEffect(.regular.interactive(), in: .circle)
                    } else {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, composerHeight + 24)
                .accessibilityLabel("Scroll to bottom")
                .zIndex(2)
            }
        }
        .sheet(item: $fileChangesReviewPayload) { payload in
            FileChangesReviewSheet(items: payload.items)
        }
        .toolbar {
            if model.canDeleteSessionsLocally, !serverViewModel.sessionId.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            showDeleteSessionConfirm = true
                        } label: {
                            Label("Delete Session", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete Session?",
            isPresented: $showDeleteSessionConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) {
                let idToDelete = serverViewModel.sessionId
                guard !idToDelete.isEmpty else { return }
                model.deleteSession(idToDelete)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the session and its cached chat history from this device.")
        }
        .alert("Undo not available", isPresented: $showUndoUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Agmente can't undo file changes yet.")
        }
    }
}

private extension CodexSessionDetailView {
    var chatTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(sessionViewModel.chatMessages) { message in
                        chatBubble(for: message)
                            .id(message.id)
                    }
                }
                .applyScrollTargetLayoutIfAvailable()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .padding(.horizontal, 12)
                .background(ChatContentMetricsReader())
            }
            .applyScrollPositionIfAvailable(id: $scrollPosition)
            .coordinateSpace(name: ChatScrollCoordinateSpace.name)
            .background(ChatScrollViewHeightReader())
            .onAppear {
                isAtBottom = true
                scrollToLastMessage(proxy: proxy, animated: false)
            }
            .onChange(of: serverViewModel.sessionId) { _, _ in
                isAtBottom = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    scrollToLastMessage(proxy: proxy, animated: false)
                }
            }
            .onChange(of: sessionViewModel.chatMessages.count) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    scrollToLastMessageIfPinned(proxy: proxy, animated: true)
                }
            }
            .onChange(of: sessionViewModel.chatMessages.last?.content) { _, _ in
                scrollToLastMessageIfPinned(proxy: proxy, animated: false)
            }
            .onChange(of: sessionViewModel.chatMessages.last?.segments.count) { _, _ in
                scrollToLastMessageIfPinned(proxy: proxy, animated: false)
            }
            .onChange(of: isTextEditorFocused) { _, focused in
                if focused {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        scrollToLastMessageIfPinned(proxy: proxy, animated: true)
                    }
                }
            }
            .onChatScrollViewHeightChange { height in
                scrollViewHeight = height
            }
            .onChatContentMetricsChange { metrics in
                if #available(iOS 17.0, *) {
                    return
                }
                updateIsAtBottom(contentHeight: metrics.height, contentMinY: metrics.minY)
            }
            .onChange(of: scrollPosition) { newValue in
                guard let lastId = sessionViewModel.chatMessages.last?.id else {
                    isAtBottom = true
                    return
                }
                isAtBottom = (newValue == lastId)
            }
            .id(serverViewModel.sessionId)
            .overlay(alignment: .top) {
                if sessionViewModel.chatMessages.isEmpty {
                    VStack(spacing: 12) {
                        PixelBot()
                        Text("let's git together and code")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 60)
                }
            }
            .onAppear {
                scrollToBottomAction = { scrollToLastMessage(proxy: proxy, animated: true) }
            }
        }
    }

    private func scrollToLastMessage(proxy: ScrollViewProxy, animated: Bool) {
        guard let lastMessage = sessionViewModel.chatMessages.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(lastMessage.id, anchor: .bottom)
        }
    }

    private func scrollToLastMessageIfPinned(proxy: ScrollViewProxy, animated: Bool) {
        guard isAtBottom else { return }
        scrollToLastMessage(proxy: proxy, animated: animated)
    }

    private func updateIsAtBottom(contentHeight: CGFloat, contentMinY: CGFloat) {
        guard scrollViewHeight > 0, contentHeight > 0 else { return }
        let threshold: CGFloat = 80
        let distanceFromBottom = contentHeight + contentMinY - scrollViewHeight
        let atBottom = distanceFromBottom <= threshold
        if isAtBottom != atBottom {
            isAtBottom = atBottom
        }
    }

    private var shouldShowScrollToBottomButton: Bool {
        !isAtBottom && !sessionViewModel.chatMessages.isEmpty
    }

    var composer: some View {
        let hasPrompt = !model.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImages = !sessionViewModel.attachedImages.isEmpty
        let hasCommand = sessionViewModel.selectedCommandName != nil
        let canSendPrompt = model.connectionState == .connected
            && !serverViewModel.sessionId.isEmpty
            && !serverViewModel.isStreaming
            && (hasPrompt || hasImages || hasCommand)
        let canCancelPrompt = serverViewModel.isStreaming && !serverViewModel.sessionId.isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            // Model picker, skills picker, and command picker row
            HStack(spacing: 12) {
                if !serverViewModel.availableModels.isEmpty {
                    modelPicker
                }

                if !serverViewModel.availableSkills.isEmpty {
                    skillsPicker
                }

                if !sessionViewModel.availableCommands.isEmpty {
                    commandPicker
                }

                Spacer()
            }
            .padding(.horizontal, 10)

            if let selectedCommand {
                selectedCommandView(for: selectedCommand)
                    .padding(.horizontal, 10)
            }

            // Text input and send button
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.promptText)
                        .focused($isTextEditorFocused)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .frame(minHeight: 36, maxHeight: textEditorHeight)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { textEditorWidth = geo.size.width }
                                    .onChange(of: geo.size.width) { _, newWidth in
                                        textEditorWidth = newWidth
                                    }
                            }
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .accessibilityIdentifier("codexPromptEditor")

                    if model.promptText.isEmpty && sessionViewModel.attachedImages.isEmpty {
                        Text(promptPlaceholderText)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(.systemGray4))
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    if serverViewModel.isStreaming {
                        // Cancel not supported for Codex yet
                    } else {
                        sendPrompt()
                    }
                } label: {
                    let isStreaming = serverViewModel.isStreaming
                    let isConnected = model.connectionState == .connected
                    Image(systemName: isStreaming ? "stop.fill" : "paperplane.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(isStreaming ? Color.primary : Color.white)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(isStreaming ? Color(.systemGray5) : (isConnected ? Color.black : Color.gray))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color(.systemGray3), lineWidth: isStreaming ? 1 : 0)
                        )
                }
                .disabled(!canSendPrompt && !canCancelPrompt)
                .buttonStyle(.plain)
                .accessibilityLabel(serverViewModel.isStreaming ? "Stop" : "Send")
                .accessibilityIdentifier("codexSendButton")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    private func sendPrompt() {
        isTextEditorFocused = false

        let promptText = model.promptText
        let images = sessionViewModel.attachedImages
        let commandName = sessionViewModel.selectedCommandName

        model.promptText = ""
        sessionViewModel.clearImageAttachments()
        sessionViewModel.selectedCommandName = nil

        serverViewModel.sendPrompt(
            promptText: promptText,
            images: images,
            commandName: commandName
        )
    }

    // Note: Mode picker removed - app-server protocol doesn't support agent/mode/list
    // Instead, Codex uses model/list for model selection

    var modelPicker: some View {
        Menu {
            // Model selection section
            Section("Model") {
                ForEach(serverViewModel.availableModels) { model in
                    Button {
                        serverViewModel.selectedModelId = model.id
                        // Reset effort to default for this model
                        serverViewModel.selectedEffort = model.defaultReasoningEffort
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                if !model.description.isEmpty {
                                    Text(model.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if serverViewModel.selectedModelId == model.id ||
                               (serverViewModel.selectedModelId == nil && model.isDefault) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            // Effort selection section (if current model supports it)
            if let selectedModel = serverViewModel.selectedModel,
               !selectedModel.supportedReasoningEfforts.isEmpty {
                Section("Reasoning Effort") {
                    ForEach(selectedModel.supportedReasoningEfforts) { option in
                        Button {
                            serverViewModel.selectedEffort = option.reasoningEffort
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.reasoningEffort.capitalized)
                                    if !option.description.isEmpty {
                                        Text(option.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if serverViewModel.selectedEffort == option.reasoningEffort {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.footnote.weight(.semibold))
                Text(currentModelDisplayName)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                if let effort = currentEffortDisplayName {
                    Text("·")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(effort)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.15))
            .foregroundStyle(.blue)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
    }

    var currentModelDisplayName: String {
        if let model = serverViewModel.selectedModel {
            return model.displayName
        }
        if let defaultModel = serverViewModel.defaultModel {
            return defaultModel.displayName
        }
        return "Model"
    }

    var currentEffortDisplayName: String? {
        guard let effort = serverViewModel.selectedEffort else { return nil }
        // Don't show "medium" as it's the default
        if effort == "medium" { return nil }
        return effort.capitalized
    }

    var skillsPicker: some View {
        Menu {
            ForEach(serverViewModel.availableSkills) { skill in
                Button {
                    toggleSkill(skill.name)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name)
                                .font(.body.weight(.medium))
                            if let shortDesc = skill.shortDescription, !shortDesc.isEmpty {
                                Text(shortDesc)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if !skill.description.isEmpty {
                                Text(skill.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text(skill.scope.rawValue.capitalized)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if serverViewModel.enabledSkillNames.contains(skill.name) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            if !serverViewModel.enabledSkillNames.isEmpty {
                Divider()
                Button(role: .destructive) {
                    serverViewModel.enabledSkillNames.removeAll()
                } label: {
                    Label("Clear All Skills", systemImage: "xmark.circle")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.footnote.weight(.semibold))
                Text(skillsDisplayText)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(serverViewModel.enabledSkillNames.isEmpty ? Color(.systemGray5) : Color.purple.opacity(0.15))
            .foregroundStyle(serverViewModel.enabledSkillNames.isEmpty ? Color.secondary : Color.purple)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
    }

    private var skillsDisplayText: String {
        let count = serverViewModel.enabledSkillNames.count
        if count == 0 {
            return "Skills"
        } else if count == 1 {
            return serverViewModel.enabledSkillNames.first ?? "1 Skill"
        } else {
            return "\(count) Skills"
        }
    }

    private func toggleSkill(_ skillName: String) {
        if serverViewModel.enabledSkillNames.contains(skillName) {
            serverViewModel.enabledSkillNames.remove(skillName)
        } else {
            serverViewModel.enabledSkillNames.insert(skillName)
        }
    }

    var commandPicker: some View {
        Menu {
            ForEach(sessionViewModel.availableCommands, id: \SessionCommand.id) { (command: SessionCommand) in
                Button {
                    sessionViewModel.selectedCommandName = command.name
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("/\(command.name)")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if sessionViewModel.selectedCommandName == command.name {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.semibold))
                                }
                            }
                            Text(command.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let hint = command.inputHint {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
            }
        } label: {
            Image(systemName: "slash.circle")
                .font(.footnote.weight(.semibold))
                .padding(8)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
    }

    func selectedCommandView(for command: SessionCommand) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "slash.circle.fill")
                        .font(.footnote.weight(.semibold))
                    Text("/\(command.name)")
                        .font(.footnote.weight(.semibold))
                }
                Text(command.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let hint = command.inputHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    sessionViewModel.selectedCommandName = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    func chatBubble(for message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            userBubble(for: message)
        case .assistant:
            assistantBubble(for: message)
        case .system:
            systemBubble(for: message)
        }
    }

    func userBubble(for message: ChatMessage) -> some View {
        UserBubble(content: message.content, images: message.images)
            .accessibilityIdentifier("codexUserBubble")
    }

    func assistantBubble(for message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let fileChangeSegments = message.segments.filter { FileChangeSummary.isFileChangeSegment($0) }
            let contentSegments = message.segments
                .filter { segment in
                    if segment.kind == .message || segment.kind == .thought {
                        return !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    return true
                }
            let displaySegments = contentSegments.groupedThoughtSegments()
            let fileChangeItems = FileChangeSummary.items(from: fileChangeSegments)
            let lastIndex = displaySegments.indices.last

            // Render segments if available, otherwise plain content
            if !displaySegments.isEmpty {
                ForEach(Array(displaySegments.enumerated()), id: \.element.id) { index, display in
                    switch display {
                    case .message(let segment):
                        AssistantTextBubble(content: segment.text)
                    case .toolCall(let segment):
                        if FileChangeSummary.isFileChangeSegment(segment) {
                            let status = segment.toolCall?.status?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let isAwaitingApproval = status == "awaiting_permission"
                                && segment.toolCall?.approvalRequestId != nil
                            let isAwaitingPermission = status == "awaiting_permission"
                                && !(segment.toolCall?.permissionOptions?.isEmpty ?? true)
                            if isAwaitingApproval || isAwaitingPermission {
                                toolCallCard(for: segment)
                            }
                        } else {
                            toolCallCard(for: segment)
                        }
                    case .thoughtGroup(let group):
                        thoughtGroupCard(
                            group,
                            isStreaming: message.isStreaming && lastIndex == index
                        )
                    }
                }
            } else if !message.content.isEmpty {
                AssistantTextBubble(content: message.content)
            }

            if !fileChangeItems.isEmpty {
                FileChangesSummaryView(
                    items: fileChangeItems,
                    onUndo: { showUndoUnavailableAlert = true },
                    onReview: {
                        guard !fileChangeItems.isEmpty else { return }
                        fileChangesReviewPayload = FileChangesReviewPayload(items: fileChangeItems)
                    }
                )
            }

            if message.isStreaming {
                ShimmeringBubble(text: "Thinking…")
                    .accessibilityIdentifier("codexThinkingBubble")
            }
        }
        .padding(.horizontal, 2)
        .accessibilityIdentifier("codexAssistantBubble")
    }

    func systemBubble(for message: ChatMessage) -> some View {
        SystemBubble(content: message.content)
            .accessibilityIdentifier("codexSystemBubble")
    }

    @ViewBuilder
    func thoughtGroupCard(_ group: ThoughtGroup, isStreaming: Bool) -> some View {
        let thoughtId = group.id
        let containsToolCall = group.blocks.contains { block in
            if case .toolCall = block { return true }
            return false
        }
        let autoExpanded = isStreaming
        let isExpanded = autoExpanded || expandedThoughts.contains(thoughtId)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedThoughts.contains(thoughtId) {
                        expandedThoughts.remove(thoughtId)
                    } else {
                        expandedThoughts.insert(thoughtId)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.footnote)
                    Text("Thinking")
                        .font(.footnote.weight(.medium))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.purple)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(group.blocks.enumerated()), id: \.element.id) { index, block in
                        switch block {
                        case .thought(let segment):
                            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    MarkdownText(content: trimmed, font: .footnote)
                                        .foregroundStyle(.primary)
                                }
                            }
                        case .toolCall(let segment):
                            thoughtToolCallBlock(segment)
                        }

                        if index != group.blocks.indices.last {
                            Divider()
                                .opacity(0.2)
                        }
                    }
                }
            }
        }
        .onChange(of: isStreaming) { isStreaming in
            if !isStreaming {
                if containsToolCall {
                    expandedThoughts.insert(thoughtId)
                } else {
                    expandedThoughts.remove(thoughtId)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.purple.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    func thoughtToolCallBlock(_ segment: AssistantSegment) -> some View {
        let title = segment.toolCall?.title ?? segment.text
        let status = segment.toolCall?.status?.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = segment.toolCall?.output?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = segment.toolCall?.kind
        let isAwaitingApproval = status == "awaiting_permission" && segment.toolCall?.approvalRequestId != nil
        let permissionOptions = segment.toolCall?.permissionOptions
        let permissionRequestId = segment.toolCall?.permissionRequestId
        let isAwaitingPermission = status == "awaiting_permission"
            && permissionOptions != nil
            && !(permissionOptions?.isEmpty ?? true)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: toolIconName(for: kind))
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer(minLength: 4)

                if let status, !status.isEmpty {
                    toolStatusIndicator(status)
                }
            }

            if let output, !output.isEmpty {
                let displayOutput = output.truncatedToolOutput(maxLines: 6, maxChars: 1_200)
                Text(displayOutput)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if isAwaitingApproval {
                codexApprovalDetails(for: segment)
            }

            if isAwaitingPermission, let options = permissionOptions, let requestId = permissionRequestId {
                permissionOptionsView(options: options, requestId: requestId)
            }
        }
    }

    func toolIconName(for kind: String?) -> String {
        switch kind?.lowercased() {
        case "execute", "command", "shell":
            return "terminal"
        case "search", "web":
            return "magnifyingglass"
        case "edit", "file", "write":
            return "pencil"
        default:
            return "hammer"
        }
    }

    @ViewBuilder
    func toolStatusIndicator(_ status: String) -> some View {
        switch status.lowercased() {
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        case "pending", "in_progress", "running":
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
        case "awaiting_permission":
            Image(systemName: "exclamationmark.shield.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    func toolCallCard(for segment: AssistantSegment) -> some View {
        let status = segment.toolCall?.status?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAwaitingApproval = status == "awaiting_permission" && segment.toolCall?.approvalRequestId != nil
        let permissionOptions = segment.toolCall?.permissionOptions
        let permissionRequestId = segment.toolCall?.permissionRequestId
        let isAwaitingPermission = status == "awaiting_permission"
            && permissionOptions != nil
            && !(permissionOptions?.isEmpty ?? true)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "hammer")
                    .font(.footnote)
                Text(segment.toolCall?.title ?? segment.text)
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(.orange)

            if let output = segment.toolCall?.output, !output.isEmpty {
                let displayOutput = output.truncatedToolOutput(maxLines: 5, maxChars: 1_200)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.footnote)
                    Text("Result")
                        .font(.footnote.weight(.medium))
                }
                .foregroundStyle(.green)
                Text(displayOutput)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isAwaitingApproval {
                codexApprovalDetails(for: segment)
            }

            if isAwaitingPermission, let options = permissionOptions, let requestId = permissionRequestId {
                permissionOptionsView(options: options, requestId: requestId)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    func codexApprovalDetails(for segment: AssistantSegment) -> some View {
        let reason = segment.toolCall?.approvalReason
        let command = segment.toolCall?.approvalCommand
        let cwd = segment.toolCall?.approvalCwd

        VStack(alignment: .leading, spacing: 6) {
            Text("Permission required")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            if let reason, !reason.isEmpty {
                Text(reason.truncatedLabel(maxChars: 160))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let command, !command.isEmpty {
                Text(command.truncatedToolOutput(maxLines: 4, maxChars: 600))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let cwd, !cwd.isEmpty {
                Text("cwd: \(cwd)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let requestId = segment.toolCall?.approvalRequestId {
                HStack(spacing: 8) {
                    Button {
                        serverViewModel.approveRequest(requestId: requestId)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle")
                                .font(.caption2)
                            Text("Approve")
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        serverViewModel.declineRequest(requestId: requestId)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                                .font(.caption2)
                            Text("Decline")
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.15))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 6)
    }

    func permissionOptionsView(options: [ACPPermissionOption], requestId: JSONRPCID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permission required")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            HStack(spacing: 8) {
                ForEach(options, id: \.optionId) { option in
                    Button {
                        model.sendPermissionResponse(requestId: requestId, optionId: option.optionId)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: iconForPermissionKind(option.kind))
                                .font(.caption2)
                            Text(option.name.truncatedLabel(maxChars: 24))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(backgroundForPermissionKind(option.kind))
                        .foregroundStyle(foregroundForPermissionKind(option.kind))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 6)
    }

    func iconForPermissionKind(_ kind: ACPPermissionOptionKind) -> String {
        switch kind {
        case .allowOnce, .allowAlways:
            return "checkmark.circle"
        case .rejectOnce, .rejectAlways:
            return "xmark.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    func backgroundForPermissionKind(_ kind: ACPPermissionOptionKind) -> Color {
        switch kind {
        case .allowOnce, .allowAlways:
            return Color.green.opacity(0.15)
        case .rejectOnce, .rejectAlways:
            return Color.red.opacity(0.15)
        case .unknown:
            return Color.gray.opacity(0.15)
        }
    }

    func foregroundForPermissionKind(_ kind: ACPPermissionOptionKind) -> Color {
        switch kind {
        case .allowOnce, .allowAlways:
            return .green
        case .rejectOnce, .rejectAlways:
            return .red
        case .unknown:
            return .primary
        }
    }
}
