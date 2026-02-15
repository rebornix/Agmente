import SwiftUI
import UIKit
import PhotosUI
import Photos
import ACPClient
import ACP

struct SessionDetailView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var serverViewModel: ServerViewModel
    @ObservedObject var sessionViewModel: ACPSessionViewModel
    @FocusState private var isTextEditorFocused: Bool
    @State private var textEditorWidth: CGFloat = 0
    @State private var showingWorkingDirectoryPicker = false
    @State private var showingImagePicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoPermissionAlert = false
    @State private var showDeleteSessionConfirm = false
    @State private var expandedThoughts: Set<UUID> = []
    @State private var showFileChangesReview = false
    @State private var fileChangesForReview: [FileChangeSummaryItem] = []
    @State private var showUndoUnavailableAlert = false
    @State private var scrollViewHeight: CGFloat = 0
    @State private var isAtBottom = true
    @State private var composerHeight: CGFloat = 0
    @State private var scrollToBottomAction: (() -> Void)?
    @State private var scrollPosition: UUID?

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
        .sheet(isPresented: $showingWorkingDirectoryPicker) {
            WorkingDirectoryPickerSheet(model: model, isPresented: $showingWorkingDirectoryPicker)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showFileChangesReview) {
            FileChangesReviewSheet(items: fileChangesForReview)
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

private extension SessionDetailView {
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
            .id(serverViewModel.sessionId) // Reset scroll state when session changes
            .overlay(alignment: .top) {
                if sessionViewModel.chatMessages.isEmpty {
                    if serverViewModel.pendingSessionLoad == serverViewModel.sessionId {
                        ProgressView("Loading session...")
                            .padding(.top, 60)
                    } else {
                        VStack(spacing: 12) {
                            PixelBot()
                            Text("let's git together and code")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 60)
                    }
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
        let composerActions = PromptComposerActions(
            canSend: canSendPrompt,
            send: {
                guard canSendPrompt else { return }
                isTextEditorFocused = false

                // Phase 2: Call ServerViewModel.sendPrompt() directly
                // Capture state before clearing
                let promptText = model.promptText
                let images = sessionViewModel.attachedImages
                let commandName = sessionViewModel.selectedCommandName

                // Clear composer immediately for responsiveness
                model.promptText = ""
                sessionViewModel.clearImageAttachments()
                sessionViewModel.selectedCommandName = nil

                // Call ServerViewModel
                serverViewModel.sendPrompt(
                    promptText: promptText,
                    images: images,
                    commandName: commandName
                )
            },
            canCancel: canCancelPrompt,
            cancel: {
                guard canCancelPrompt else { return }
                model.sendCancel()
            }
        )

        return VStack(alignment: .leading, spacing: 8) {
            // Mode picker, working directory, and image attachment row
            HStack(spacing: 12) {
                // Mode picker (if modes available)
                if !model.availableModes.isEmpty {
                    modePicker
                }
                
                // Working directory button
                Button {
                    showingWorkingDirectoryPicker = true
                } label: {
                    Image(systemName: "folder")
                        .font(.footnote.weight(.semibold))
                        .padding(8)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(model.currentSessionCwd.isEmpty ? .secondary : .primary)
                }

                if !sessionViewModel.availableCommands.isEmpty {
                    commandPicker
                }

                // Image attachment button
                imageAttachmentButton
                
                Spacer()
            }
            .padding(.horizontal, 10)

            if let selectedCommand {
                selectedCommandView(for: selectedCommand)
                    .padding(.horizontal, 10)
            }

            // Image attachment preview (if any images attached)
            if !sessionViewModel.attachedImages.isEmpty {
                imageAttachmentPreview
                    .padding(.horizontal, 10)
            }

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
                        composerActions.cancel()
                    } else {
                        composerActions.send()
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
                .disabled(!(canSendPrompt || canCancelPrompt))
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .focusedSceneValue(\.promptComposerActions, composerActions)
        .onChange(of: selectedPhotoItems) { _, newItems in
            Task {
                await loadSelectedPhotos(newItems)
                selectedPhotoItems = []
            }
        }
    }

    // MARK: - Slash Commands
    
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
//                                        .foregroundStyle(.accentColor)
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
                .background(
                    Color(.systemGray5)
                )
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

    // MARK: - Image Attachment Button
    
    @ViewBuilder
    var imageAttachmentButton: some View {
        let supportsImages = sessionViewModel.supportsImageAttachment
        let canAttach = sessionViewModel.canAttachMoreImages
        let maxSelection = ImageProcessor.maxAttachments - sessionViewModel.attachedImages.count

        Button {
            Task {
                let granted = await requestPhotoLibraryAccess()
                await MainActor.run {
                    if granted {
                        showingImagePicker = true
                    } else {
                        showPhotoPermissionAlert = true
                    }
                }
            }
        } label: {
            Image(systemName: "photo")
                .font(.footnote.weight(.semibold))
                .padding(8)
                .background(supportsImages ? Color(.systemGray5) : Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(supportsImages ? .primary : .quaternary)
        }
        .disabled(!canAttach)
        .photosPicker(
            isPresented: $showingImagePicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: maxSelection,
            matching: .images,
            photoLibrary: .shared()
        )
        .alert("Allow Agmente to access your photos?", isPresented: $showPhotoPermissionAlert) {
            Button("OK", role: .cancel) { }
        }
    }
    
    // MARK: - Image Attachment Preview
    
    var imageAttachmentPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessionViewModel.attachedImages) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: attachment.thumbnail())
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(.systemGray4), lineWidth: 1)
                            )
                        
                        // Remove button
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                sessionViewModel.removeImageAttachment(attachment.id)
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, Color(.systemGray))
                                .background(Circle().fill(Color(.systemBackground)).padding(2))
                        }
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    // MARK: - Photo Loading
    
    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard sessionViewModel.canAttachMoreImages else { break }
            
            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    _ = await MainActor.run {
                        sessionViewModel.addImageAttachment(image)
                    }
                }
            } catch {
            }
        }
    }

    private func requestPhotoLibraryAccess() async -> Bool {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        switch currentStatus {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return status == .authorized || status == .limited
        case .restricted, .denied:
            return false
        @unknown default:
            return false
        }
    }

    @ViewBuilder
    func chatBubble(for message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            userBubble(content: message.content, images: message.images)
        case .assistant:
            assistantBubble(message: message)
        case .system:
            if message.isError {
                errorBubble(content: message.content)
            } else {
                systemBubble(content: message.content)
            }
        }
    }

    func userBubble(content: String, images: [ChatImageData] = []) -> some View {
        UserBubble(content: content, images: images)
    }

    func assistantBubble(message: ChatMessage) -> some View {
        assistantContentView(message: message)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    func assistantContentView(message: ChatMessage) -> some View {
        let segments = displaySegments(for: message)
        let fileChangeSegments = segments.filter { FileChangeSummary.isFileChangeSegment($0) }
        let contentSegments = segments
            .filter { !FileChangeSummary.isFileChangeSegment($0) }
        let displaySegments = contentSegments.groupedThoughtSegments()
        let fileChangeItems = FileChangeSummary.items(from: fileChangeSegments)
        let lastIndex = displaySegments.indices.last

        VStack(alignment: .leading, spacing: 8) {
            if displaySegments.isEmpty && message.isStreaming {
                shimmeringBubble(text: "Thinking…")
            }

            ForEach(Array(displaySegments.enumerated()), id: \.element.id) { index, display in
                switch display {
                case .thoughtGroup(let group):
                    let text = group.combinedText
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        thoughtBubble(
                            text: text,
                            isStreaming: message.isStreaming && lastIndex == index,
                            isExpanded: expandedThoughts.contains(group.id)
                        ) {
                            toggleThoughtExpansion(for: group.id)
                        }
                    }
                case .message(let segment):
                    if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownText(content: segment.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                case .toolCall(let segment):
                    toolCallBubble(segment: segment, isStreaming: message.isStreaming && lastIndex == index)
                case .plan(let segment):
                    if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownText(content: segment.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }

            if !fileChangeItems.isEmpty {
                FileChangesSummaryView(
                    items: fileChangeItems,
                    onUndo: { showUndoUnavailableAlert = true },
                    onReview: {
                        fileChangesForReview = fileChangeItems
                        showFileChangesReview = true
                    }
                )
            }
        }
    }

    func displaySegments(for message: ChatMessage) -> [AssistantSegment] {
        if !message.segments.isEmpty {
            // Filter out empty message segments during display
            return message.segments.filter { segment in
                if segment.kind == .message || segment.kind == .thought {
                    return !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return true // Always show tool calls
            }
        }

        return parseAssistantContent(message.content).compactMap { segment in
            // Skip empty non-tool-call segments
            if !segment.isToolCall && segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            if segment.isToolCall {
                let parsed = parseToolCallDisplay(from: segment.text)
                return AssistantSegment(
                    kind: .toolCall,
                    text: parsed.title,
                    toolCall: parsed
                )
            }
            return AssistantSegment(kind: .message, text: segment.text)
        }
    }

    struct ContentSegment {
        let text: String
        let isToolCall: Bool
    }

    func parseAssistantContent(_ content: String) -> [ContentSegment] {
        var segments: [ContentSegment] = []
        var currentText = ""

        let lines = content.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("Tool call:") {
                // Save any accumulated text
                if !currentText.isEmpty {
                    segments.append(ContentSegment(text: currentText.trimmingCharacters(in: .whitespacesAndNewlines), isToolCall: false))
                    currentText = ""
                }
                // Add tool call segment
                segments.append(ContentSegment(text: line, isToolCall: true))
            } else {
                if !currentText.isEmpty {
                    currentText += "\n"
                }
                currentText += line
            }
        }

        // Add remaining text
        if !currentText.isEmpty {
            segments.append(ContentSegment(text: currentText.trimmingCharacters(in: .whitespacesAndNewlines), isToolCall: false))
        }

        return segments
    }

    func parseToolCallDisplay(from text: String) -> ToolCallDisplay {
        var displayContent = text
        if displayContent.hasPrefix("Tool call: ") {
            displayContent = String(displayContent.dropFirst("Tool call: ".count))
        }

        var toolKind: String? = nil
        if displayContent.hasPrefix("["), let endBracket = displayContent.firstIndex(of: "]") {
            toolKind = String(displayContent[displayContent.index(after: displayContent.startIndex)..<endBracket])
            displayContent = String(displayContent[displayContent.index(after: endBracket)...]).trimmingCharacters(in: .whitespaces)
        }

        var status: String? = nil
        if let statusStart = displayContent.lastIndex(of: "("),
           let statusEnd = displayContent.lastIndex(of: ")"),
           statusStart < statusEnd {
            status = String(displayContent[displayContent.index(after: statusStart)..<statusEnd])
            displayContent = String(displayContent[..<statusStart]).trimmingCharacters(in: .whitespaces)
        }

        return ToolCallDisplay(toolCallId: nil, title: displayContent, kind: toolKind, status: status)
    }

    func toolCallBubble(segment: AssistantSegment, isStreaming: Bool) -> some View {
        let displayContent = segment.toolCall?.title ?? segment.text.replacingOccurrences(of: "Tool call: ", with: "")
        let toolKind = segment.toolCall?.kind
        let status = segment.toolCall?.status
        let output = segment.toolCall?.output
        let permissionOptions = segment.toolCall?.permissionOptions
        let permissionRequestId = segment.toolCall?.acpPermissionRequestId

        let iconName = iconForToolKind(toolKind)
        let iconColor = colorForToolKind(toolKind)
        let isAwaitingPermission = status == "awaiting_permission" && permissionOptions != nil && !permissionOptions!.isEmpty

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: isAwaitingPermission ? "shield.lefthalf.filled" : iconName)
                    .font(.footnote)
                    .foregroundStyle(isAwaitingPermission ? .orange : iconColor)

                Text(displayContent)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer()

                // Show status indicator
                if isAwaitingPermission {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if isStreaming && (status == nil || status == "in_progress" || status == "pending") {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.6)
                } else if status == "completed" {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                } else if status == "failed" {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            // Show permission options if awaiting permission
            if isAwaitingPermission, let options = permissionOptions, let requestId = permissionRequestId {
                permissionOptionsView(options: options, requestId: requestId)
            }

            // Show output if present
            if let output, !output.isEmpty {
                let displayOutput = output.truncatedToolOutput(maxLines: 6, maxChars: 1_200)
                Text(displayOutput)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isAwaitingPermission ? Color.orange.opacity(0.1) : iconColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isAwaitingPermission ? Color.orange.opacity(0.5) : iconColor.opacity(0.3), lineWidth: isAwaitingPermission ? 2 : 1)
        )
    }

    func permissionOptionsView(options: [ACPPermissionOption], requestId: ACP.ID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permission required")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.top, 4)
            
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

    var modePicker: some View {
        Menu {
            let modes: [AgentModeOption] = model.availableModes
            ForEach(modes, id: \AgentModeOption.id) { (mode: AgentModeOption) in
                Button {
                    model.sendSetMode(mode.id)
                } label: {
                    HStack {
                        Text(mode.name)
                        if sessionViewModel.currentModeId == mode.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconForMode(sessionViewModel.currentModeId))
                    .font(.footnote.weight(.semibold))
                Text(currentModeName)
                    .font(.footnote.weight(.medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(colorForMode(sessionViewModel.currentModeId).opacity(0.15))
            .foregroundStyle(colorForMode(sessionViewModel.currentModeId))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
    }

    var currentModeName: String {
        if let modeId = sessionViewModel.currentModeId,
           let mode = model.availableModes.first(where: { $0.id == modeId }) {
            return mode.name
        }
        return model.availableModes.first?.name ?? "Mode"
    }

    func iconForMode(_ modeId: String?) -> String {
        guard let modeId = modeId?.lowercased() else { return "slider.horizontal.3" }
        
        switch modeId {
        case "plan", "architect":
            return "list.bullet.clipboard"
        case "code", "auto-edit":
            return "chevron.left.forwardslash.chevron.right"
        case "ask", "chat":
            return "bubble.left.and.bubble.right"
        case "yolo", "auto":
            return "bolt.fill"
        case "debug":
            return "ladybug"
        default:
            return "slider.horizontal.3"
        }
    }

    func colorForMode(_ modeId: String?) -> Color {
        guard let modeId = modeId?.lowercased() else { return .blue }
        
        switch modeId {
        case "plan", "architect":
            return .purple
        case "code", "auto-edit":
            return .orange
        case "ask", "chat":
            return .blue
        case "yolo", "auto":
            return .red
        case "debug":
            return .green
        default:
            return .blue
        }
    }

    func thoughtBubble(text: String, isStreaming: Bool, isExpanded: Bool, toggle: @escaping () -> Void) -> some View {
        let lineCount = text.components(separatedBy: "\n").count
        let shouldTruncate = text.count > 240 || lineCount > 5

        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                MarkdownText(content: text, font: .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded || !shouldTruncate ? nil : 6)

                if shouldTruncate {
                    Button(action: toggle) {
                        Text(isExpanded ? "Show less" : "Show more")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderless)
                }
            }

            Spacer()

            if isStreaming {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    func toggleThoughtExpansion(for id: UUID) {
        if expandedThoughts.contains(id) {
            expandedThoughts.remove(id)
        } else {
            expandedThoughts.insert(id)
        }
    }

    func iconForToolKind(_ kind: String?) -> String {
        switch kind {
        case "read": return "doc.text.magnifyingglass"
        case "edit": return "pencil"
        case "delete": return "trash"
        case "move": return "arrow.right.doc.on.clipboard"
        case "search": return "magnifyingglass"
        case "execute": return "terminal"
        case "think": return "brain"
        case "fetch": return "arrow.down.circle"
        default: return "wrench.and.screwdriver"
        }
    }

    func colorForToolKind(_ kind: String?) -> Color {
        switch kind {
        case "read": return .blue
        case "edit": return .orange
        case "delete": return .red
        case "execute": return .purple
        case "search": return .green
        case "think": return .indigo
        case "fetch": return .cyan
        default: return .orange
        }
    }

    func systemBubble(content: String) -> some View {
        SystemBubble(content: content)
    }

    func errorBubble(content: String) -> some View {
        ErrorBubble(content: content)
    }

    func shimmeringBubble(text: String) -> some View {
        ShimmeringBubble(text: text)
    }

}

// MARK: - Command Picker Sheet

// struct CommandPickerSheet: View {
//     let commands: [SessionCommand]
//     @Binding var selectedCommandName: String?
//     @Binding var isPresented: Bool

//     var body: some View {
//         NavigationStack {
//             if commands.isEmpty {
//                 VStack(spacing: 12) {
//                     Image(systemName: "slash.circle")
//                         .font(.system(size: 36))
//                         .foregroundStyle(.secondary)
//                     Text("No commands available")
//                         .foregroundStyle(.secondary)
//                 }
//                 .frame(maxWidth: .infinity, maxHeight: .infinity)
//                 .background(Color(.systemGroupedBackground))
//             } else {
//                 List(commands) { command in
//                     Button {
//                         selectedCommandName = command.name
//                         isPresented = false
//                     } label: {
//                         HStack(alignment: .top, spacing: 10) {
//                             VStack(alignment: .leading, spacing: 4) {
//                                 HStack(spacing: 6) {
//                                     Text("/\(command.name)")
//                                         .font(.body.weight(.semibold))
//                                         .foregroundStyle(.primary)
//                                     if selectedCommandName == command.name {
//                                         Image(systemName: "checkmark")
//                                             .font(.footnote.weight(.semibold))
//                                             .foregroundStyle(.accentColor)
//                                     }
//                                 }
//                                 Text(command.description)
//                                     .font(.subheadline)
//                                     .foregroundStyle(.secondary)
//                                 if let hint = command.inputHint {
//                                     Text(hint)
//                                         .font(.caption)
//                                         .foregroundStyle(.secondary)
//                                 }
//                             }
//                             Spacer()
//                         }
//                         .padding(.vertical, 6)
//                     }
//                     .buttonStyle(.plain)
//                 }
//                 .listStyle(.insetGrouped)
//             }
//             .navigationTitle("Slash Commands")
//             .navigationBarTitleDisplayMode(.inline)
//             .toolbar {
//                 ToolbarItem(placement: .cancellationAction) {
//                     Button("Cancel") { isPresented = false }
//                 }
//                 ToolbarItem(placement: .confirmationAction) {
//                     if selectedCommandName != nil {
//                         Button("Clear") { selectedCommandName = nil }
//                     }
//                 }
//             }
//         }
//     }
// }

// MARK: - Working Directory Picker Sheet

struct WorkingDirectoryPickerSheet: View {
    @ObservedObject var model: AppViewModel
    @Binding var isPresented: Bool
    @State private var pendingWorkingDirectory: String = ""
    
    var body: some View {
        NavigationStack {
            List {
                // Current session's working directory
                Section {
                    if model.isPendingSession {
                        TextField("Working directory", text: $pendingWorkingDirectory)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .font(.body.monospaced())
                    } else {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(model.currentSessionCwd.isEmpty ? "Not set" : model.currentSessionCwd)
                                .foregroundStyle(model.currentSessionCwd.isEmpty ? .secondary : .primary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
                    Text("This Session")
                } footer: {
                    if model.isPendingSession {
                        Text("Change the working directory for this pending session before sending your first message.")
                    } else {
                        Text("The working directory for the current session. This is set when the session is created and cannot be changed.")
                    }
                }
                
                // Server's default working directory
                Section {
                    if model.isPendingSession {
                        Button {
                            pendingWorkingDirectory = model.workingDirectory
                        } label: {
                            HStack {
                                Image(systemName: "folder.badge.gearshape")
                                    .foregroundStyle(.orange)
                                Text(model.workingDirectory.isEmpty ? "Not set" : model.workingDirectory)
                                    .foregroundStyle(model.workingDirectory.isEmpty ? .secondary : .primary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Spacer()
                                if pendingWorkingDirectory == model.workingDirectory {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack {
                            Image(systemName: "folder.badge.gearshape")
                                .foregroundStyle(.orange)
                            Text(model.workingDirectory.isEmpty ? "Not set" : model.workingDirectory)
                                .foregroundStyle(model.workingDirectory.isEmpty ? .secondary : .primary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
                    Text("Server Default")
                } footer: {
                        Text("New sessions will use this directory. You can change this in server settings.")
                }

                let excluded = Set([
                    model.currentSessionCwd.trimmingCharacters(in: .whitespacesAndNewlines),
                    model.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                ].filter { !$0.isEmpty })
                let history = model.usedWorkingDirectoryHistory.filter { !excluded.contains($0) }

                if !history.isEmpty {
                    Section {
                        ForEach(history, id: \.self) { directory in
                            if model.isPendingSession {
                                Button {
                                    pendingWorkingDirectory = directory
                                } label: {
                                    HStack {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                        Text(directory)
                                            .font(.body.monospaced())
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        if pendingWorkingDirectory == directory {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            } else {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                    Text(directory)
                                        .font(.body.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                }
                                .contextMenu {
                                    Button("Copy") {
                                        UIPasteboard.general.string = directory
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Previously Used")
                    } footer: {
                        Text(model.isPendingSession ? "Tap to fill the working directory." : "Long-press a row to copy.")
                    }
                }
            }
            .navigationTitle("Working Directory")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                pendingWorkingDirectory = model.currentSessionCwd
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isPendingSession ? "Save" : "Done") {
                        if model.isPendingSession {
                            model.updatePendingSessionWorkingDirectory(pendingWorkingDirectory)
                        }
                        isPresented = false
                    }
                }
            }
        }
    }
}