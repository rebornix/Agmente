import SwiftUI

/// Provides Button-like actions for the chat composer so we can expose them via focused scene values.
struct PromptComposerActions {
    var canSend: Bool
    var send: () -> Void
    var canCancel: Bool
    var cancel: () -> Void
}

private struct PromptComposerActionsKey: FocusedValueKey {
    typealias Value = PromptComposerActions
}

extension FocusedValues {
    var promptComposerActions: PromptComposerActions? {
        get { self[PromptComposerActionsKey.self] }
        set { self[PromptComposerActionsKey.self] = newValue }
    }
}

#if os(macOS) || targetEnvironment(macCatalyst)
struct PromptComposerCommands: Commands {
    @FocusedValue(\.promptComposerActions) private var composerActions

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            if let composerActions {
                Button("Send Message") {
                    composerActions.send()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!composerActions.canSend)

                Button("Cancel Response") {
                    composerActions.cancel()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!composerActions.canCancel)
            }
        }
    }
}
#endif