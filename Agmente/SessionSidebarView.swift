import SwiftUI

struct SessionSidebarView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var serverViewModel: ServerViewModel
    @ObservedObject var sessionViewModel: ACPSessionViewModel
    var showConnectionAndInit: Bool = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if showConnectionAndInit {
                    connectionSection
                    initializeSection
                }
                sessionSection
                logSection
            }
            .padding()
        }
    }
}

private extension SessionSidebarView {
    var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection").font(.headline)
            Picker("Protocol", selection: $model.scheme) {
                Text("ws").tag("ws")
                Text("wss").tag("wss")
            }
            .pickerStyle(.segmented)
            .disabled(model.selectedServerId == nil)

            TextField("Host", text: $model.endpointHost)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .disabled(model.selectedServerId == nil)

            SecureField("Bearer token (optional)", text: $model.token)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
                .disabled(model.selectedServerId == nil)

            TextField("CF Access Client ID (optional)", text: $model.cfAccessClientId)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
                .disabled(model.selectedServerId == nil)

            SecureField("CF Access Client Secret (optional)", text: $model.cfAccessClientSecret)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
                .disabled(model.selectedServerId == nil)

            HStack {
                Text(model.stateLabel(model.connectionState))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.connect()
                } label: {
                    Label("Connect", systemImage: "bolt")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedServerId == nil || model.connectionState == .connected || model.isConnecting)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var initializeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Initialize").font(.headline)
            HStack {
                VStack(alignment: .leading) {
                    Text("Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Client name", text: $model.clientName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.selectedServerId == nil)
                }
                VStack(alignment: .leading) {
                    Text("Version")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Version", text: $model.clientVersion)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.selectedServerId == nil)
                }
            }
            Toggle("Supports FS read", isOn: $model.supportsFSRead).disabled(model.selectedServerId == nil)
            Toggle("Supports FS write", isOn: $model.supportsFSWrite).disabled(model.selectedServerId == nil)
            Toggle("Supports terminal", isOn: $model.supportsTerminal).disabled(model.selectedServerId == nil)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("Status")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.initializationSummary)
                        .font(.subheadline)
                }
                Spacer()
                Button("Initialize", action: model.sendInitialize)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedServerId == nil || model.connectionState != .connected)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions").font(.headline)
                Spacer()
                Button {
                    model.sendNewSession()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .disabled(model.selectedServerId == nil || model.connectionState != .connected)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Default working dir: ")
                    TextField("/", text: $model.workingDirectory)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.selectedServerId == nil)
                }

            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

            if serverViewModel.sessionSummaries.isEmpty {
                Text("Most ACP agents do not expose session/list; sessions are cached locally while this app is running.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(serverViewModel.sessionSummaries) { session in
                        Button {
                            model.openSession(session.id)
                        } label: {
                            SessionCard(
                                title: session.title ?? "New Chat",
                                subtitle: "Session",
                                isSelected: serverViewModel.selectedSessionId == session.id,
                                isDimmed: model.connectionState != .connected
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !sessionViewModel.stopReason.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text("Last stop: \(sessionViewModel.stopReason)")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Messages").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.updates) { update in
                        Text(update.formattedLine)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}