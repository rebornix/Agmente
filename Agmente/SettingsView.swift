import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @Binding var devModeEnabled: Bool
    @Binding var codexSessionLoggingEnabled: Bool
    var sessionLogger: CodexSessionLogger?

    @State private var isExportingLogs = false
    @State private var exportedLogURL: URL?
    @State private var exportError: String?
    @State private var showDeleteConfirmation = false

    @ViewBuilder
    private var settingsFormContainer: some View {
#if os(macOS)
        ScrollView {
            Form {
                settingsSections
            }
            .formStyle(.grouped)
            .frame(maxWidth: 620)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
#else
        Form {
            settingsSections
        }
#endif
    }

    @ViewBuilder
    private var settingsSections: some View {
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
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Developer mode", isOn: $devModeEnabled)
                Text("Shows extra diagnostics like connection status on server cards.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Codex session logging", isOn: $codexSessionLoggingEnabled)
                Text("Writes per-session JSONL logs for Codex app-server. Stored in Application Support.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if codexSessionLoggingEnabled {
                Button {
                    exportSessionLogs()
                } label: {
                    HStack {
                        Text("Share Session Logs")
                        Spacer()
                        if isExportingLogs {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isExportingLogs)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Text("Delete All Logs")
                        Spacer()
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
                .alert("Delete All Logs?", isPresented: $showDeleteConfirmation) {
                    Button("Delete", role: .destructive) {
                        deleteAllLogs()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently remove all Codex session log files.")
                }

                if let exportError {
                    Text(exportError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            settingsFormContainer
            .navigationTitle("Settings")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
#if os(macOS)
        .frame(minWidth: 640, idealWidth: 680, minHeight: 420, idealHeight: 500)
#endif
        .sheet(isPresented: Binding(
            get: { exportedLogURL != nil },
            set: { if !$0 { exportedLogURL = nil } }
        )) {
            if let url = exportedLogURL {
                ShareSheetView(activityItems: [url])
            }
        }
    }
    
    private func openFeedbackEmail() {
        let email = "info@halliharp.com"
        let subject = "Agmente Feedback"
        let urlString = "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        
        if let url = URL(string: urlString) {
#if os(iOS)
            UIApplication.shared.open(url)
#else
            NSWorkspace.shared.open(url)
#endif
        }
    }

    private func deleteAllLogs() {
        guard let logger = sessionLogger else { return }
        Task { await logger.deleteAllLogs() }
    }

    private func exportSessionLogs() {
        guard let logger = sessionLogger else {
            exportError = "Session logger not available."
            return
        }
        isExportingLogs = true
        exportError = nil

        Task.detached {
            let logFiles = logger.collectLogFileURLs()
            guard !logFiles.isEmpty else {
                await MainActor.run {
                    isExportingLogs = false
                    exportError = "No log files found."
                }
                return
            }

            let tempDir = FileManager.default.temporaryDirectory
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let timestamp = formatter.string(from: Date())
            let zipName = "codex-logs-\(timestamp).zip"
            let zipURL = tempDir.appendingPathComponent(zipName)

            // Remove previous export if exists
            try? FileManager.default.removeItem(at: zipURL)

            // Create a directory with the logs then zip it
            let stagingDir = tempDir.appendingPathComponent("codex-logs-staging-\(timestamp)")
            try? FileManager.default.removeItem(at: stagingDir)
            try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            for logFile in logFiles {
                let dest = stagingDir.appendingPathComponent(logFile.lastPathComponent)
                try? FileManager.default.copyItem(at: logFile, to: dest)
            }

            // Use NSFileCoordinator to create a zip
            var error: NSError?
            let coordinator = NSFileCoordinator()
            var resultURL: URL?
            coordinator.coordinate(
                readingItemAt: stagingDir,
                options: .forUploading,
                error: &error
            ) { zippedURL in
                let finalURL = tempDir.appendingPathComponent(zipName)
                try? FileManager.default.removeItem(at: finalURL)
                try? FileManager.default.copyItem(at: zippedURL, to: finalURL)
                resultURL = finalURL
            }

            // Cleanup staging
            try? FileManager.default.removeItem(at: stagingDir)

            await MainActor.run {
                isExportingLogs = false
                if let url = resultURL {
                    exportedLogURL = url
                } else {
                    exportError = error?.localizedDescription ?? "Failed to create log archive."
                }
            }
        }
    }
}

#if os(iOS)
private struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
private struct ShareSheetView: View {
    let activityItems: [Any]

    var body: some View {
        VStack(spacing: 12) {
            Text("Log file exported")
                .font(.headline)
            if let url = activityItems.first as? URL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .padding()
        .frame(minWidth: 300, minHeight: 120)
    }
}
#endif

#Preview {
    SettingsView(
        devModeEnabled: .constant(true),
        codexSessionLoggingEnabled: .constant(false)
    )
}
