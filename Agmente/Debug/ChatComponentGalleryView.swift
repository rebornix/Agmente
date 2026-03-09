#if DEBUG && canImport(UIKit)
import SwiftUI
import UIKit
import ACP
import ACPClient

enum ChatGalleryPreset: String, CaseIterable, Identifiable {
    case codex = "Codex"
    case acp = "ACP"

    var id: Self { self }
}

private struct ChatGalleryScenario {
    let summary: String
    let messages: [ChatMessage]
}

struct ChatComponentGalleryView: View {
    @State private var preset: ChatGalleryPreset
    @State private var transcriptState = ChatTranscriptState()

    init(initialPreset: ChatGalleryPreset = .codex) {
        _preset = State(initialValue: initialPreset)
    }

    private var scenario: ChatGalleryScenario {
        ChatComponentMockData.scenario(for: preset)
    }

    var body: some View {
        ZStack {
            Color(.systemGray6)
                .ignoresSafeArea()

            ChatTranscriptContainerView(
                state: transcriptState,
                messages: scenario.messages,
                contentInsets: .zero,
                actionHandlers: .none
            )
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            transcriptControls
        }
        .navigationTitle("Test Transcript")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var transcriptControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Preset", selection: $preset) {
                ForEach(ChatGalleryPreset.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)

            Text(scenario.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(.systemGray6))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private enum ChatComponentMockData {
    static let sampleImages: [ChatImageData] = [
    ].compactMap { $0 }

    static let componentThoughtText = """
    I mapped the transcript into display segments and verified each row kind is visible in the preview.
    """

    static let componentPlanText = """
    1. Keep a single gallery screen for all row kinds.
    2. Add segmented controls for preset data.
    3. Use debug-only compilation so production builds stay unchanged.
    """

    static let componentToolCall: AssistantSegment = {
        AssistantSegment(
            kind: .toolCall,
            text: "Run formatter",
            toolCall: ToolCallDisplay(
                toolCallId: "tool-preview-1",
                title: "Run formatter",
                kind: "execute",
                status: "awaiting_permission",
                output: nil,
                permissionOptions: permissionOptions([
                    ("allow_once", "Allow once", "allow_once"),
                    ("allow_always", "Allow always", "allow_always"),
                    ("reject_once", "Reject", "reject_once")
                ]),
                acpPermissionRequestId: nil,
                permissionRequestId: .string("permission-preview"),
                approvalRequestId: .string("approval-preview"),
                approvalKind: "command",
                approvalReason: "Formatter needs permission to edit files in the workspace.",
                approvalCommand: "swiftformat .",
                approvalCwd: "/Users/lvpeng/Code/Agmente-oss"
            )
        )
    }()

    static let compactMultilineToolCallA: AssistantSegment = {
        AssistantSegment(
            kind: .toolCall,
            text: "",
            toolCall: ToolCallDisplay(
                toolCallId: "tool-compact-long-1",
                title: #"ps -Ao rss,command | rg \"Visual Studio Code - Insiders|Code - Insiders Helper|code-insiders\" | awk '{sum+=$1} END {printf "Total VS Code Insiders RSS: %.1f MB\\n", sum/1024}'"#,
                kind: "execute",
                status: "completed",
                output: nil
            )
        )
    }()

    static let compactMultilineToolCallB: AssistantSegment = {
        AssistantSegment(
            kind: .toolCall,
            text: "",
            toolCall: ToolCallDisplay(
                toolCallId: "tool-compact-long-2",
                title: #"ps -Ao pid,rss,command | rg \"Visual Studio Code - Insiders|Code - Insiders Helper|code-insiders\" | awk '{rss_mb=$2/1024; pid=$1; $1=""; $2=""; sub(/^  */, ""); printf "%6s %8.1f MB  %s\\n", pid, rss_mb, $0}' | sort -k2 -nr | head -n 15"#,
                kind: "execute",
                status: "completed",
                output: nil
            )
        )
    }()

    static let componentFileChanges: [FileChangeSummaryItem] = [
        FileChangeSummaryItem(
            id: "gallery-file-1",
            title: "Update: Agmente/ChatRendering/ChatTranscriptContainerView.swift",
            path: "Agmente/ChatRendering/ChatTranscriptContainerView.swift",
            verb: "update",
            status: "completed",
            diff: "@@ -1,3 +1,8 @@\n+ Added preview-only gallery render path."
        ),
        FileChangeSummaryItem(
            id: "gallery-file-2",
            title: "Create: Agmente/Debug/ChatComponentGalleryView.swift",
            path: "Agmente/Debug/ChatComponentGalleryView.swift",
            verb: "create",
            status: "completed",
            diff: "@@ -0,0 +1,180 @@\n+ Debug gallery with mock data."
        )
    ]

    static var componentUserPreviewMessages: [ChatMessage] {
        [
            ChatMessage(
                role: .user,
                content: "Please compare rendering approaches with mock data.",
                isStreaming: false,
                images: sampleImages
            )
        ]
    }

    static var componentAssistantTextPreviewMessages: [ChatMessage] {
        [
            ChatMessage(
                role: .assistant,
                content: "",
                isStreaming: false,
                segments: [
                    AssistantSegment(kind: .message, text: "This is the shared assistant markdown bubble.")
                ]
            )
        ]
    }

    static var componentThoughtPreviewMessages: [ChatMessage] {
        [
            ChatMessage(
                role: .assistant,
                content: "",
                isStreaming: false,
                segments: [
                    AssistantSegment(kind: .thought, text: componentThoughtText)
                ]
            )
        ]
    }

    static var componentPlanPreviewMessages: [ChatMessage] {
        [
            ChatMessage(
                role: .assistant,
                content: "",
                isStreaming: false,
                segments: [
                    AssistantSegment(kind: .plan, text: componentPlanText)
                ]
            )
        ]
    }

    static var componentToolCallPreviewMessages: [ChatMessage] {
        [
            ChatMessage(
                role: .assistant,
                content: "",
                isStreaming: false,
                segments: [componentToolCall]
            )
        ]
    }

    static var componentFileChangesPreviewMessages: [ChatMessage] {
        [
            ChatMessage(
                role: .assistant,
                content: "",
                isStreaming: false,
                segments: [
                    fileChangeSegment(
                        id: "tool-component-file-1",
                        title: "Update: Agmente/ChatRendering/ChatTranscriptContainerView.swift",
                        path: "Agmente/ChatRendering/ChatTranscriptContainerView.swift"
                    ),
                    fileChangeSegment(
                        id: "tool-component-file-2",
                        title: "Create: Agmente/Debug/ChatComponentGalleryView.swift",
                        path: "Agmente/Debug/ChatComponentGalleryView.swift"
                    )
                ]
            )
        ]
    }

    static var componentSystemPreviewMessages: [ChatMessage] {
        [
            ChatMessage(
                role: .system,
                content: "Connected to ws://127.0.0.1:8788",
                isStreaming: false
            )
        ]
    }

    static var componentErrorPreviewMessages: [ChatMessage] {
        [
            ChatMessage(
                role: .system,
                content: "Failed to send the previous turn.",
                isStreaming: false,
                isError: true
            )
        ]
    }

    static var componentStreamingPreviewMessages: [ChatMessage] {
        [
            ChatMessage(
                role: .assistant,
                content: "",
                isStreaming: true,
                segments: [
                    AssistantSegment(kind: .thought, text: "Thinking through the next step.")
                ]
            )
        ]
    }

    static func scenario(for preset: ChatGalleryPreset) -> ChatGalleryScenario {
        switch preset {
        case .codex:
            return ChatGalleryScenario(
                summary: "Codex-like thread with plan, tool calls, file changes, and streaming states.",
                messages: codexMessages()
            )
        case .acp:
            return ChatGalleryScenario(
                summary: "ACP-like session with permission prompts and mixed assistant content.",
                messages: acpMessages()
            )
        }
    }

    private static func codexMessages() -> [ChatMessage] {
        let user = ChatMessage(
            role: .user,
            content: "Can you show the transcript and all base components in one page?",
            isStreaming: false,
            images: sampleImages
        )

        let assistant = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: false,
            segments: [
                AssistantSegment(
                    kind: .message,
                    text: "I verified the shared transcript renderer and its component coverage."
                ),
                AssistantSegment(kind: .thought, text: componentThoughtText),
                compactMultilineToolCallA,
                compactMultilineToolCallB,
                AssistantSegment(
                    kind: .toolCall,
                    text: "Inspect transcript files",
                    toolCall: ToolCallDisplay(
                        toolCallId: "tool-codex-1",
                        title: "Inspect transcript files",
                        kind: "search",
                        status: "completed",
                        output: "Found 5 files under Agmente/ChatRendering/HighPerformanceChatListView."
                    )
                ),
                AssistantSegment(kind: .plan, text: componentPlanText),
                fileChangeSegment(
                    id: "tool-codex-file-1",
                    title: "Update: Agmente/CodexSessionDetailView.swift",
                    path: "Agmente/CodexSessionDetailView.swift"
                ),
                fileChangeSegment(
                    id: "tool-codex-file-2",
                    title: "Create: Agmente/Debug/ChatComponentGalleryView.swift",
                    path: "Agmente/Debug/ChatComponentGalleryView.swift"
                ),
                componentToolCall
            ]
        )

        let streamingAssistant = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: true,
            segments: [
                AssistantSegment(kind: .thought, text: "Applying the final touches to the gallery and previews.")
            ]
        )

        let system = ChatMessage(
            role: .system,
            content: "Connected to ws://127.0.0.1:8788",
            isStreaming: false
        )

        let error = ChatMessage(
            role: .system,
            content: "Last turn interrupted by user.",
            isStreaming: false,
            isError: true
        )

        return [system, user, assistant, streamingAssistant, error]
    }

    private static func acpMessages() -> [ChatMessage] {
        let user = ChatMessage(
            role: .user,
            content: "Please run tests and summarize the changed files.",
            isStreaming: false
        )

        let assistant = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: false,
            segments: [
                AssistantSegment(
                    kind: .message,
                    text: "I can run tests first, then summarize the edits."
                ),
                AssistantSegment(
                    kind: .toolCall,
                    text: "Run unit tests",
                    toolCall: ToolCallDisplay(
                        toolCallId: "tool-acp-1",
                        title: "Run unit tests",
                        kind: "execute",
                        status: "failed",
                        output: "Test suite failed in 1 file."
                    )
                ),
                AssistantSegment(
                    kind: .toolCall,
                    text: "Open diagnostics",
                    toolCall: ToolCallDisplay(
                        toolCallId: "tool-acp-2",
                        title: "Open diagnostics",
                        kind: "read",
                        status: "awaiting_permission",
                        output: nil,
                        permissionOptions: permissionOptions([
                            ("allow_once", "Allow once", "allow_once"),
                            ("reject_once", "Reject", "reject_once")
                        ]),
                        acpPermissionRequestId: nil,
                        permissionRequestId: .int(7)
                    )
                ),
                AssistantSegment(
                    kind: .plan,
                    text: """
                    1. Re-run failing tests with verbose logs.
                    2. Capture stack traces for the top failure.
                    3. Summarize root cause and fix options.
                    """
                )
            ]
        )

        let system = ChatMessage(
            role: .system,
            content: "Session loaded from local cache",
            isStreaming: false
        )

        return [system, user, assistant]
    }

    private static func fileChangeSegment(id: String, title: String, path: String) -> AssistantSegment {
        AssistantSegment(
            kind: .toolCall,
            text: title,
            toolCall: ToolCallDisplay(
                toolCallId: id,
                title: title,
                kind: "edit_file",
                status: "completed",
                output: "@@ -1,2 +1,3 @@\n+ // Updated in preview gallery for \(path)"
            )
        )
    }

    private static func permissionOptions(
        _ values: [(optionId: String, name: String, kind: String)]
    ) -> [ACPPermissionOption] {
        let options = values.map { value in
            ACP.Value.object([
                "optionId": .string(value.optionId),
                "name": .string(value.name),
                "kind": .string(value.kind)
            ])
        }

        let params = ACP.Value.object([
            "toolCall": .object(["title": .string("Mock tool call")]),
            "options": .array(options)
        ])

        return ACPPermissionRequestParser.parse(params: params)?.options ?? []
    }

    private static func makeImageData(label: String, color: UIColor) -> ChatImageData? {
        let size = CGSize(width: 320, height: 180)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 64, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = (label as NSString).size(withAttributes: attributes)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (label as NSString).draw(in: textRect, withAttributes: attributes)
        }

        guard let attachment = ImageProcessor.processImage(image, resize: false) else {
            return nil
        }
        return ChatImageData(from: attachment)
    }
}

private struct ChatCoreComponentsListView: View {
    @State private var actionLog = "Tap action buttons to preview handlers."

    private var actionHandlers: ChatEntryActionHandlers {
        ChatEntryActionHandlers(
            onACPPermissionResponse: { requestId, optionId in
                actionLog = "ACP permission response: \(String(describing: requestId)) -> \(optionId)"
            },
            onJSONRPCPermissionResponse: { requestId, optionId in
                let idLabel: String
                switch requestId {
                case .string(let value):
                    idLabel = value
                case .int(let value):
                    idLabel = String(value)
                }
                actionLog = "JSON-RPC permission response: \(idLabel) -> \(optionId)"
            },
            onApproveRequest: { requestId, acceptForSession in
                let idLabel: String
                switch requestId {
                case .string(let value):
                    idLabel = value
                case .int(let value):
                    idLabel = String(value)
                }
                let suffix = acceptForSession == true ? " (session)" : ""
                actionLog = "Approved request: \(idLabel)\(suffix)"
            },
            onDeclineRequest: { requestId in
                let idLabel: String
                switch requestId {
                case .string(let value):
                    idLabel = value
                case .int(let value):
                    idLabel = String(value)
                }
                actionLog = "Declined request: \(idLabel)"
            },
            onUndoFileChanges: {
                actionLog = "Undo tapped"
            },
            onReviewFileChanges: { items in
                actionLog = "Review tapped (\(items.count) file change\(items.count == 1 ? "" : "s"))"
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Core Components")
                    .font(.title2.weight(.bold))
                Text("Component catalog preview (no device chrome).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                CoreComponentsCatalog(actionHandlers: actionHandlers, actionLog: $actionLog)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGray6))
    }
}

private struct CoreComponentsCatalog: View {
    let actionHandlers: ChatEntryActionHandlers
    @Binding var actionLog: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RealRendererComponentPreview(
                title: "UserBubble",
                messages: ChatComponentMockData.componentUserPreviewMessages,
                height: 170,
                actionHandlers: actionHandlers
            )

            RealRendererComponentPreview(
                title: "AssistantTextBubble",
                messages: ChatComponentMockData.componentAssistantTextPreviewMessages,
                height: 110,
                actionHandlers: actionHandlers
            )

            RealRendererComponentPreview(
                title: "Thought",
                messages: ChatComponentMockData.componentThoughtPreviewMessages,
                height: 120,
                actionHandlers: actionHandlers
            )

            RealRendererComponentPreview(
                title: "ProposedPlanCard",
                messages: ChatComponentMockData.componentPlanPreviewMessages,
                height: 170,
                actionHandlers: actionHandlers
            )

            RealRendererComponentPreview(
                title: "ToolCallCard",
                messages: ChatComponentMockData.componentToolCallPreviewMessages,
                height: 240,
                actionHandlers: actionHandlers
            )

            RealRendererComponentPreview(
                title: "FileChangesSummaryView",
                messages: ChatComponentMockData.componentFileChangesPreviewMessages,
                height: 170,
                actionHandlers: actionHandlers
            )

            RealRendererComponentPreview(
                title: "SystemBubble",
                messages: ChatComponentMockData.componentSystemPreviewMessages,
                height: 70,
                actionHandlers: actionHandlers
            )

            RealRendererComponentPreview(
                title: "ErrorBubble",
                messages: ChatComponentMockData.componentErrorPreviewMessages,
                height: 70,
                actionHandlers: actionHandlers
            )

            RealRendererComponentPreview(
                title: "ShimmeringBubble",
                messages: ChatComponentMockData.componentStreamingPreviewMessages,
                height: 100,
                actionHandlers: actionHandlers
            )

            Text("Action Log")
                .font(.headline)
            Text(actionLog)
                .font(.footnote.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RealRendererComponentPreview: View {
    let title: String
    let messages: [ChatMessage]
    let height: CGFloat
    let actionHandlers: ChatEntryActionHandlers
    @State private var transcriptState = ChatTranscriptState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ChatTranscriptContainerView(
                state: transcriptState,
                messages: messages,
                contentInsets: ChatTranscriptInsets(top: 8, left: 0, bottom: 8, right: 0),
                actionHandlers: actionHandlers
            )
            .frame(height: height)
        }
    }
}

#Preview("Core Components", traits: .fixedLayout(width: 560, height: 1400)) {
    ChatCoreComponentsListView()
}

#Preview("Transcript Gallery", traits: .fixedLayout(width: 760, height: 1400)) {
    ChatComponentGalleryView(initialPreset: .codex)
}
#endif
