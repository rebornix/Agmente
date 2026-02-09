import SwiftUI

struct SettingsView: View {
    @Binding var devModeEnabled: Bool
    @Binding var codexSessionLoggingEnabled: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Feedback") {
                    Button {
                        openFeedbackEmail()
                    } label: {
                        HStack {
                            Text("Send Feedback")
                            Spacer()
                            Image(systemName: "envelope")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Section("Developer") {
                    Toggle("Developer mode", isOn: $devModeEnabled)
                    Text("Shows extra diagnostics like connection status on server cards.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("Codex session logging", isOn: $codexSessionLoggingEnabled)
                    Text("Writes per-session JSONL logs for Codex app-server. Stored in Application Support.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func openFeedbackEmail() {
        let email = "info@halliharp.com"
        let subject = "Agmente Feedback"
        let urlString = "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    SettingsView(devModeEnabled: .constant(true), codexSessionLoggingEnabled: .constant(false))
}