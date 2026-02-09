import SwiftUI
import ACPClient

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var name: String = ""
    @State private var scheme: String = "ws"
    @State private var host: String = ""
    @State private var token: String = ""
    @State private var cfAccessClientId: String = ""
    @State private var cfAccessClientSecret: String = ""
    @State private var workingDirectory: String = ""
    @State private var serverType: ServerType = .acp
    @State private var showCloudflareAccess: Bool = false
    @State private var isSaving = false
    @State private var isNormalizingHost = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var pendingValidation: ValidatedServerConfiguration?
    @State private var showingSummaryOverlay = false
    @State private var hasAttemptedSave = false

    let editingServer: ACPServerConfiguration?
    let onValidate: (String, String, String, String, String, String, String, ServerType) async -> Result<ValidatedServerConfiguration, Error>
    let onInsert: (ValidatedServerConfiguration) -> Void

    init(
        editingServer: ACPServerConfiguration? = nil,
        onValidate: @escaping (String, String, String, String, String, String, String, ServerType) async -> Result<ValidatedServerConfiguration, Error>,
        onInsert: @escaping (ValidatedServerConfiguration) -> Void
    ) {
        self.editingServer = editingServer
        self.onValidate = onValidate
        self.onInsert = onInsert

        _name = State(initialValue: editingServer?.name ?? "")
        _scheme = State(initialValue: editingServer?.scheme ?? "ws")
        _host = State(initialValue: editingServer?.host ?? "")
        _token = State(initialValue: editingServer?.token ?? "")
        _cfAccessClientId = State(initialValue: editingServer?.cfAccessClientId ?? "")
        _cfAccessClientSecret = State(initialValue: editingServer?.cfAccessClientSecret ?? "")
        _workingDirectory = State(initialValue: editingServer?.workingDirectory ?? "")
        _serverType = State(initialValue: editingServer?.serverType ?? .acp)
        _showCloudflareAccess = State(initialValue: !(editingServer?.cfAccessClientId ?? "").isEmpty)
    }

    private enum Field: Hashable {
        case name
        case host
        case token
        case cfAccessClientId
        case cfAccessClientSecret
        case workingDirectory
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    Section {
                        TextField("Display name", text: $name)
                            .focused($focusedField, equals: .name)
                            .accessibilityIdentifier("ServerNameField")
                    }

                    Section {
                        Picker("Server Type", selection: $serverType) {
                            Text("ACP")
                                .tag(ServerType.acp)
                                .accessibilityIdentifier("ServerTypeACP")
                                .accessibilityLabel("ACP")
                            Text("Codex")
                                .tag(ServerType.codexAppServer)
                                .accessibilityIdentifier("ServerTypeCodex")
                                .accessibilityLabel("Codex App-Server")
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("ServerTypePicker")
                    } footer: {
                        Text(serverType.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Picker("Protocol", selection: $scheme) {
                            Text("ws").tag("ws")
                            Text("wss").tag("wss")
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("ProtocolPicker")

                        TextField("Host", text: $host)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .onChange(of: host, perform: normalizeHostInput)
                            .focused($focusedField, equals: .host)
                            .accessibilityIdentifier("HostField")

                        SecureField("Bearer token (optional)", text: $token)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .focused($focusedField, equals: .token)
                    }

                    Section {
                        TextField("Working directory", text: $workingDirectory)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .focused($focusedField, equals: .workingDirectory)
                    } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            if hasAttemptedSave && isWorkingDirectoryEmpty && !allowsEmptyWorkingDirectory {
                                Label("A working directory is required for the agent to operate safely.", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.footnote)
                            }
                            if hasAttemptedSave && isWorkingDirectoryRoot {
                                Label("Using root (/) as working directory is dangerous and may crash the agent.", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.footnote)
                            }
                            Link(destination: URL(string: "https://agmente.halliharp.com/docs/guides/local-agent")!) {
                                Label("Need help? View the setup guide", systemImage: "questionmark.circle")
                            }
                            .font(.footnote)
                        }
                    }

                    Section {
                        DisclosureGroup("Cloudflare Access", isExpanded: $showCloudflareAccess) {
                            TextField("Client ID", text: $cfAccessClientId)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .focused($focusedField, equals: .cfAccessClientId)

                            SecureField("Client Secret", text: $cfAccessClientSecret)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .focused($focusedField, equals: .cfAccessClientSecret)
                        }
                    }

                    Section {
                        Button {
                            saveServer()
                        } label: {
                            HStack {
                                Spacer()
                                if isSaving {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .padding(.trailing, 8)
                                }
                                Text(editingServer == nil ? "Save Server" : "Update Server")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .disabled(!canSave)
                        .accessibilityIdentifier("SaveServerButton")
                        .accessibilityLabel(editingServer == nil ? "Save Server" : "Update Server")
                    }
                }
                .blur(radius: showingSummaryOverlay ? 3 : 0)
                .allowsHitTesting(!showingSummaryOverlay)

                if let validation = pendingValidation, showingSummaryOverlay {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .transition(.opacity)

                    ServerSummaryOverlay(
                        validation: validation,
                        workingDirectory: trimmedWorkingDirectory,
                        isEditing: editingServer != nil,
                        onConfirm: acknowledgeAndInsert,
                        onCancel: hideSummaryOverlay
                    )
                    .padding(.horizontal, 20)
                    .transition(.scale)
                }
            }
            .navigationTitle(editingServer == nil ? "Add Server" : "Edit Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveServer()
                    } label: {
                        HStack(spacing: 8) {
                            if isSaving {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            }
                            Text(editingServer == nil ? "Save" : "Update")
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .alert(editingServer == nil ? "Unable to Add Server" : "Unable to Update Server", isPresented: $showError) {
            Button("OK", role: .cancel) {
                showError = false
            }
        } message: {
            Text(errorMessage ?? "Failed to connect to the server. Check the endpoint and credentials, then try again.")
        }
    }
}

private extension AddServerView {
    var trimmedWorkingDirectory: String {
        workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var isWorkingDirectoryEmpty: Bool {
        trimmedWorkingDirectory.isEmpty
    }
    
    var isWorkingDirectoryRoot: Bool {
        trimmedWorkingDirectory == "/"
    }

    var allowsEmptyWorkingDirectory: Bool {
        true
    }
    
    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSaving
    }
    
    func saveServer() {
        guard !isSaving else { return }
        focusedField = nil
        hasAttemptedSave = true

        if isWorkingDirectoryEmpty && !allowsEmptyWorkingDirectory {
            return
        }

        performSave()
    }
    
    func performSave() {
        isSaving = true
        let normalized = normalizeEndpointInput(host: host, scheme: scheme)
        Task {
            let result = await onValidate(
                name,
                normalized.scheme,
                normalized.host,
                token,
                cfAccessClientId,
                cfAccessClientSecret,
                workingDirectory,
                serverType
            )
            await MainActor.run {
                isSaving = false
                switch result {
                case .success(let validation):
                    pendingValidation = validation
                    showingSummaryOverlay = true
                case .failure(let error):
                    // Check if this is a local network permission error
                    // If so, don't show an error alert to avoid interfering with the OS permission prompt
                    if let validationError = error as? AppViewModel.AddServerValidationError,
                       case .localNetworkPermissionNeeded = validationError {
                        // Don't show error alert for local network permission issues
                        // The OS will show its permission prompt, and user can try again after granting
                        return
                    }
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
    
    func normalizeHostInput(_ value: String) {
        guard !isNormalizingHost else { return }
        let normalized = normalizeEndpointInput(host: value, scheme: scheme)
        guard normalized.host != value || normalized.scheme != scheme else { return }

        isNormalizingHost = true
        host = normalized.host
        scheme = normalized.scheme
        isNormalizingHost = false
    }

    func normalizeEndpointInput(host: String, scheme: String) -> (scheme: String, host: String) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseScheme = scheme.isEmpty ? "ws" : scheme

        guard let components = URLComponents(string: trimmedHost),
              let parsedHost = components.host
        else {
            return (baseScheme, trimmedHost)
        }

        let portString = components.port.map { ":\($0)" } ?? ""
        let path = components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let fragment = components.percentEncodedFragment.map { "#\($0)" } ?? ""

        let normalizedHost = parsedHost + portString + path + query + fragment
        let normalizedScheme = components.scheme ?? baseScheme

        return (normalizedScheme.isEmpty ? "ws" : normalizedScheme, normalizedHost)
    }

    func hideSummaryOverlay() {
        showingSummaryOverlay = false
        pendingValidation = nil
    }

    func acknowledgeAndInsert() {
        guard let validation = pendingValidation else { return }
        onInsert(validation)
        hideSummaryOverlay()
        dismiss()
    }
}

private struct ServerSummaryOverlay: View {
    let validation: ValidatedServerConfiguration
    let workingDirectory: String
    let isEditing: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var displayName: String {
        let trimmed = validation.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "\(validation.scheme)://\(validation.host)"
        }
        return trimmed
    }
    
    private var isWorkingDirectoryRoot: Bool {
        workingDirectory == "/"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review agent limitations")
                        .font(.title3.weight(.semibold))
                    Text("Before inserting \(displayName), confirm what this agent reports supporting.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss summary overlay")
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Authentication notice (always shown)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "person.badge.key.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Authentication Required")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Make sure you have authenticated with the agent CLI (OAuth, API key, etc.) before connecting. Agmente does not handle agent authentication.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.blue.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
                    
                    // Root directory warning
                    if isWorkingDirectoryRoot {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Root Directory Warning")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("You are using root (/) as the working directory. The agent will have access to your entire filesystem, which may cause system instability or data loss.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.red.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.red.opacity(0.3), lineWidth: 1)
                        )
                    }
                    
                    if let agentInfo = validation.agentInfo {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(agentInfo.displayNameWithVersion)
                                .font(.headline)
                            if let description = agentInfo.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            AgentCapabilitiesSummary(
                                capabilities: agentInfo.capabilities,
                                verifications: agentInfo.verifications
                            )
                        }
                    } else {
                        Label {
                            Text("This agent did not provide capability details during validation. You can continue, but some features may be unavailable.")
                                .font(.subheadline)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.systemGray6))
                        )
                    }
                }
            }
            .frame(maxHeight: 360)

            VStack(spacing: 10) {
                Button(action: onConfirm) {
                    Text(isEditing ? "Acknowledge and Update" : "Acknowledge and Add")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onCancel) {
                    Text("Back to editing")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(radius: 18)
    }
}