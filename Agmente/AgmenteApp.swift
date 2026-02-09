import SwiftUI


@main
struct AgmenteApp: App {
    init() {
    }
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
#if os(macOS) || targetEnvironment(macCatalyst)
        .commands {
            PromptComposerCommands()
        }
#endif
    }
}
