import SwiftUI
import ACPClient

private let healthyGreen = Color(.sRGB, red: 73/255, green: 210/255, blue: 123/255, opacity: 1)

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = AppViewModel()
    @State private var showingAddServer = false
    @State private var showingSettings = false
    @State private var navigationPath: [NavigationDestination] = []
    @State private var serverToDelete: ACPServerConfiguration?
    @State private var serverToEdit: ACPServerConfiguration?
    @State private var previousServerId: UUID?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $navigationPath) {
            rootContent
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .navigationDestination(for: NavigationDestination.self, destination: destinationView)
        }
        .sheet(isPresented: $showingAddServer, content: addServerSheet)
        .sheet(item: $serverToEdit, content: editServerSheet)
        .sheet(isPresented: $showingSettings, content: settingsSheet)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                model.resumeConnectionIfNeeded()
            }
        }
        .onChange(of: model.selectedServerId) { oldServerId, newServerId in
            // Track server changes to prevent auto-navigation on server switch.
            // We skip one session ID change after a server switch to avoid
            // navigating to a pre-existing session on the new server.
            if oldServerId != newServerId {
                previousServerId = oldServerId
            }
        }
        .onChange(of: model.serverSessionId) { oldValue, newValue in
            // Skip auto-navigation only if:
            // 1. We just switched servers (previousServerId differs from current)
            // 2. AND the new server already had a session (oldValue was empty, newValue is pre-existing)
            //
            // DO navigate when:
            // - Creating a NEW session (regardless of server switch state)
            // - Initial app launch
            if previousServerId != nil && previousServerId != model.selectedServerId {
                // We just switched servers. Check if this is a pre-existing session
                // vs a newly created one. For newly created sessions, oldValue would
                // have been "" (empty) just before the session was created.
                // For pre-existing sessions on server switch, both old and new
                // could be the previously stored session ID.
                previousServerId = model.selectedServerId
                
                // If oldValue was empty and newValue is non-empty, this is a new session
                // creation that happened right after server switch - we should navigate.
                // Otherwise, it's the server switch revealing an existing session - skip.
                if !oldValue.isEmpty {
                    return
                }
            }

            let preserved = navigationPath.filter { destination in
                if case .developerLogs = destination { return true }
                return false
            }

            if newValue.isEmpty {
                navigationPath = preserved
            } else if navigationPath.last != .session(newValue) {
                navigationPath = preserved + [.session(newValue)]
            }
        }
        .onAppear {
            // Auto-navigate to last session on app launch (previousServerId is nil initially)
            let sessionId = model.serverSessionId
            if !sessionId.isEmpty {
                let preserved = navigationPath.filter { destination in
                    if case .developerLogs = destination { return true }
                    return false
                }
                navigationPath = preserved + [.session(sessionId)]
            }
        }
        .alert("Delete Server", isPresented: .init(
            get: { serverToDelete != nil },
            set: { if !$0 { serverToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                serverToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let server = serverToDelete {
                    model.deleteServer(server.id)
                    serverToDelete = nil
                }
            }
        } message: {
            if let server = serverToDelete {
                Text("Are you sure you want to delete \"\(server.name)\"? This will remove all cached sessions for this server.")
            }
        }
    }
}

private extension ContentView {
    @ViewBuilder
    var rootContent: some View {
        if model.selectedServerId == nil {
            SessionPlaceholderView(onAddServer: { showingAddServer = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .background(Color(.systemGroupedBackground))
                .ignoresSafeArea()
        } else {
            SessionListPage(model: model, navigationPath: $navigationPath)
        }
    }

    @ViewBuilder
    func destinationView(_ destination: NavigationDestination) -> some View {
        switch destination {
        case .session(let sessionId):
            // Phase 1: Open session in .task to avoid side effects in view body,
            // then conditionally render SessionDetailView with the current session's view model.
            // Use .id() to force re-render when session state changes.
            Group {
                if let serverViewModel = model.selectedServerViewModel,
                   let sessionViewModel = serverViewModel.currentSessionViewModel {
                    // ACP server
                    SessionDetailView(
                        model: model,
                        serverViewModel: serverViewModel,
                        sessionViewModel: sessionViewModel
                    )
                } else if let codexViewModel = model.selectedCodexServerViewModel,
                          let sessionViewModel = codexViewModel.currentSessionViewModel {
                    // Codex server
                    CodexSessionDetailView(
                        model: model,
                        serverViewModel: codexViewModel,
                        sessionViewModel: sessionViewModel
                    )
                } else {
                    // Fallback while session is loading
                    ProgressView("Loading session...")
                }
            }
            // Force view re-evaluation when session state changes
            .id(model.serverSessionId)
            .task {
                model.openSession(sessionId)
            }
        case .developerLogs:
            DeveloperLogsView(model: model)
        }
    }

    func addServerSheet() -> some View {
        AddServerView(
            onValidate: { name, scheme, host, token, cfAccessClientId, cfAccessClientSecret, workingDirectory, serverType in
                await model.validateServerConfiguration(
                    name: name,
                    scheme: scheme,
                    host: host,
                    token: token,
                    cfAccessClientId: cfAccessClientId,
                    cfAccessClientSecret: cfAccessClientSecret,
                    workingDirectory: workingDirectory,
                    serverType: serverType
                )
            },
            onInsert: { validated in
                model.addValidatedServer(validated)
            }
        )
    }

    func editServerSheet(_ server: ACPServerConfiguration) -> some View {
        AddServerView(
            editingServer: server,
            onValidate: { name, scheme, host, token, cfAccessClientId, cfAccessClientSecret, workingDirectory, serverType in
                await model.validateServerConfiguration(
                    name: name,
                    scheme: scheme,
                    host: host,
                    token: token,
                    cfAccessClientId: cfAccessClientId,
                    cfAccessClientSecret: cfAccessClientSecret,
                    workingDirectory: workingDirectory,
                    serverType: serverType
                )
            },
            onInsert: { validated in
                model.updateServer(server.id, with: validated)
            }
        )
    }

    func settingsSheet() -> some View {
        SettingsView(
            devModeEnabled: $model.devModeEnabled,
            codexSessionLoggingEnabled: $model.codexSessionLoggingEnabled
        )
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(model.servers) { server in
                    Button {
                        model.selectServer(server.id)
                    } label: {
                        HStack {
                            Text(server.name)
                            Spacer()
                            if server.id == model.selectedServerId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button {
                    showingAddServer = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .accessibilityIdentifier("addServerMenuAction")
            } label: {
                if #available(iOS 26.0, *) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(model.connectionState == .connected ? Color.green : Color.orange)
                            .frame(width: 9, height: 9)
                        Text(model.currentServerName)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect()
                } else {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(model.connectionState == .connected ? Color.green : Color.orange)
                            .frame(width: 9, height: 9)
                        Text(model.currentServerName)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .buttonStyle(.plain)
                }
            }
        }
        
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }

                Button {
                    Task { await model.refreshSessions() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button(action: model.disconnect) {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
                .disabled(model.connectionState == .disconnected)

                if let current = model.servers.first(where: { $0.id == model.selectedServerId }) {
                    Button {
                        serverToEdit = current
                    } label: {
                        Label("Edit Server", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        serverToDelete = current
                    } label: {
                        Label("Delete \"\(current.name)\"", systemImage: "trash")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("moreMenuButton")
        }
    }
}

private struct SessionListPage: View {
    @ObservedObject var model: AppViewModel
    @Binding var navigationPath: [NavigationDestination]
    @Environment(\.colorScheme) private var colorScheme
    @State private var sessionSearchText: String = ""
    @State private var showingNewSessionSheet: Bool = false
    @State private var customWorkingDirectory: String = ""
    @AppStorage("summaryCardCollapsed") private var summaryCardCollapsed: Bool = false
    private static let lastConnectedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private var activeSessions: [SessionSummary] {
        // Only show as active if the session is actually streaming (agent is responding)
        guard model.serverIsStreaming,
              !model.serverSessionId.isEmpty else { return [] }
        let sessionId = model.serverSessionId
        let sessions = model.serverSessionSummaries.filter { $0.id == sessionId }
        return filterSessions(sessions)
    }

    private var idleSessions: [SessionSummary] {
        // All sessions except the one that's actively streaming
        let activeIds = activeSessions.map { $0.id }
        let sessions = model.serverSessionSummaries.filter { !activeIds.contains($0.id) }
        return filterSessions(sessions)
    }

    private var groupedSessions: [(group: SessionTimeGroup, sessions: [SessionDisplay])] {
        var buckets: [SessionTimeGroup: [SessionDisplay]] = [:]
        let filtered = filterSessions(model.serverSessionSummaries)
        let activeId = model.serverIsStreaming ? model.serverSessionId : nil

        for summary in filtered {
            let group = SessionTimeGroup.group(for: summary.updatedAt)
            let display = SessionDisplay(summary: summary, isActive: summary.id == activeId)
            buckets[group, default: []].append(display)
        }

        return SessionTimeGroup.displayOrder.compactMap { group in
            guard let sessions = buckets[group] else { return nil }
            let sorted = sessions.sorted { lhs, rhs in
                switch (lhs.summary.updatedAt, rhs.summary.updatedAt) {
                case let (lhsDate?, rhsDate?):
                    if lhsDate != rhsDate { return lhsDate > rhsDate }
                    return lhs.summary.id < rhs.summary.id
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.summary.id < rhs.summary.id
                }
            }
            return (group, sorted)
        }
    }
    
    private var searchPlacement: SearchFieldPlacement {
        if #available(iOS 26.0, *) {
            return .toolbar
        } else {
            return .navigationBarDrawer(displayMode: .automatic)
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard
                    
                    if model.serverSessionSummaries.isEmpty {
                        PixelBot()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                        VStack(spacing: 8) {
                            Text("Start a new session to chat with your agent")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            
                            Link(destination: URL(string: "https://agmente.halliharp.com/docs/guides/local-agent")!) {
                                Label("Setup guide", systemImage: "book")
                                    .font(.footnote)
                            }
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                    } else {
                        ForEach(groupedSessions, id: \.group) { group, sessions in
                            sessionSection(title: group.title, sessions: sessions)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
            }
            .refreshable {
                await model.refreshSessions()
            }
            
            if #available(iOS 26.0, *) {
//                Spacer(minLength: 0)
            } else {
                footerActions
            }
        }
        .searchable(
            text: $sessionSearchText,
            placement: searchPlacement,
            prompt: "Search sessions"
        )
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .sheet(isPresented: $showingNewSessionSheet) {
            NewSessionSheet(
                workingDirectory: $customWorkingDirectory,
                usedWorkingDirectories: model.usedWorkingDirectoryHistory,
                onCancel: { showingNewSessionSheet = false },
                onCreate: {
                    model.sendNewSession(workingDirectory: customWorkingDirectory)
                    showingNewSessionSheet = false
                }
            )
        }
        .toolbar {
            if #available(iOS 26.0, *) {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)

//                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    newSessionButton(expanded: true)
                        .padding(.horizontal, 4)
                }
//                ToolbarSpacer(.flexible, placement: .bottomBar)
            }
        }
        .onAppear {
            if model.connectionState == .disconnected && !model.isConnecting {
                model.connect()
            }
        }
    }

    private var summaryCard: some View {
        let active = activeSessions.count
        let idle = idleSessions.count
        // Use serverAgentInfo (reads from @Published ServerViewModel.agentInfo) instead of
        // currentAgentInfo (reads from non-@Published agentInfoCache) to ensure view updates
        let agentDisplayName = model.serverAgentInfo?.displayNameWithVersion
        let agentCapabilities = model.serverAgentInfo?.capabilities
        let capabilityVerifications = model.serverAgentInfo?.verifications ?? []
        let lastConnectedLabel = model.lastConnectedAt.map { Self.lastConnectedFormatter.string(from: $0) } ?? "—"
        // Only show ACP capabilities for ACP servers (not Codex app-server)
        let isACPServer = model.selectedServer?.serverType == .acp
        // Only ACP servers have expandable content (capabilities); Codex app-server protocol doesn't provide modes/capabilities
        let hasExpandableContent = isACPServer

        return VStack(alignment: .leading, spacing: 12) {
                // Header row with agent name and collapse toggle
                HStack(alignment: .top) {
                    // Agent name (or server name fallback for Codex)
                    if let agentName = agentDisplayName, !agentName.isEmpty {
                        Text(agentName)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                    } else if let serverName = model.selectedServer?.name {
                        Text(serverName)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                    }
                    
                    Spacer()
                    
                    // Collapse/expand toggle - only show if there's expandable content (ACP servers only)
                    if hasExpandableContent {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                summaryCardCollapsed.toggle()
                            }
                        } label: {
                            Image(systemName: summaryCardCollapsed ? "chevron.down" : "chevron.up")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color(.systemGray5).opacity(0.6))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Collapsible content - ACP servers only (Codex app-server doesn't provide capabilities)
                if !summaryCardCollapsed && hasExpandableContent {
                    if let capabilities = agentCapabilities {
                        AgentCapabilitiesSummary(
                            capabilities: capabilities,
                            verifications: capabilityVerifications
                        )
                    }
                }

                // Active/idle stats (always visible)
                HStack(spacing: 8) {
                    // Always show Codex badge for Codex servers
                    if !isACPServer {
                        HStack(spacing: 4) {
                            Image(systemName: "server.rack")
                                .font(.caption2)
                            Text("Codex")
                                .font(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.green.opacity(0.15))
                        )
                        .foregroundStyle(.green)
                    }
                    
                    HStack(spacing: 6) {
                        Circle()
                            .fill(healthyGreen)
                            .frame(width: 8, height: 8)
                        Text("\(active) active")
                            .font(.caption.weight(.medium))
                    }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(.systemGray4))
                            .frame(width: 8, height: 8)
                        Text("\(idle) idle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    
                    // Show logs button when collapsed and dev mode enabled
                    if summaryCardCollapsed && model.devModeEnabled {
                        Spacer()
                        
                        Button {
                            navigationPath.append(.developerLogs)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.caption2)
                                Text("Logs")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Dev mode status (always visible when enabled)
                if model.devModeEnabled {
                    HStack(alignment: .center, spacing: 8) {
                        HStack (spacing: 2) {
                            Image(systemName: model.connectionState == .connected ? "bolt.fill" : "bolt.slash.fill")
                                .font(.caption2)
                            Text(model.stateLabel(model.connectionState))
                                .font(.caption.weight(.medium))
                        }

                        Text(lastConnectedLabel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(model.connectionState == .connected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
            }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .modifier(SessionCardStyle())
        .contentShape(Rectangle())
        .onTapGesture {
            guard model.devModeEnabled && !summaryCardCollapsed else { return }
            navigationPath.append(.developerLogs)
        }
    }

    private func newSessionButton(expanded: Bool) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                newSessionButtonModern(expanded: expanded)
            } else {
                newSessionButtonLegacy(expanded: expanded)
            }
        }
    }
    
    @available(iOS 26.0, *)
    private func newSessionButtonModern(expanded: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                guard model.connectionState == .connected else { return }
                model.sendNewSession()
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: expanded ? .infinity : nil)
            }
            .buttonStyle(.borderedProminent)
            .tint(.black)
            .foregroundStyle(.white)
            .controlSize(.large)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 0, topTrailingRadius: 0))
            .accessibilityIdentifier("newSessionButton")
            
            Menu {
                Button {
                    guard model.connectionState == .connected else { return }
                    customWorkingDirectory = model.workingDirectory
                    showingNewSessionSheet = true
                } label: {
                    Label("Custom Working Directory…", systemImage: "folder")
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: 32, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.black)
            .foregroundStyle(.white)
            .controlSize(.large)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 10, topTrailingRadius: 10))
            .accessibilityIdentifier("newSessionMenuButton")
        }
        .opacity(model.connectionState != .connected ? 0.7 : 1)
    }
    
    private func newSessionButtonLegacy(expanded: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                guard model.connectionState == .connected else { return }
                model.sendNewSession()
            } label: {
                Label("New Session", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: expanded ? .infinity : nil)
                    .frame(height: 50)
                    .background(.black)
                    .foregroundStyle(.white)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 0, topTrailingRadius: 0))
            }
            .buttonStyle(.plain)
            
            Menu {
                Button {
                    guard model.connectionState == .connected else { return }
                    customWorkingDirectory = model.workingDirectory
                    showingNewSessionSheet = true
                } label: {
                    Label("Custom Working Directory…", systemImage: "folder")
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: 50, height: 50)
                    .background(.black)
                    .foregroundStyle(.white)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 10, topTrailingRadius: 10))
            }
        }
        .opacity(model.connectionState != .connected ? 0.7 : 1)
    }

    private var footerActions: some View {
        HStack {
            newSessionButton(expanded: true)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private func filterSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        let lower = query.lowercased()
        return sessions.filter {
            ($0.title?.lowercased().contains(lower) ?? false) || $0.id.lowercased().contains(lower)
        }
    }

    private func sessionSection(title: String, sessions: [SessionDisplay]) -> some View {
        let defaultCwd = model.defaultWorkingDirectory

        return VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 12) {
                ForEach(sessions) { session in
                    let summary = session.summary
                    let displayCwd = summary.cwd ?? defaultCwd
                    NavigationLink(value: NavigationDestination.session(summary.id)) {
                        SessionRow(
                            title: summary.title ?? "New Chat",
                            lastMessage: model.selectedServerId.flatMap {
                                model.getLastMessagePreview(for: $0, sessionId: summary.id)
                            },
                            cwd: displayCwd,
                            isActive: session.isActive
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct SessionDisplay: Identifiable {
    let summary: SessionSummary
    let isActive: Bool

    var id: String { summary.id }
}

private enum SessionTimeGroup: CaseIterable, Hashable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case earlier
    case unknown

    var title: String {
        switch self {
        case .today:
            return "Today"
        case .yesterday:
            return "Yesterday"
        case .thisWeek:
            return "This week"
        case .lastWeek:
            return "Last week"
        case .thisMonth:
            return "This month"
        case .lastMonth:
            return "Last month"
        case .earlier:
            return "Earlier"
        case .unknown:
            return "Unknown"
        }
    }

    static var displayOrder: [SessionTimeGroup] {
        [.today, .yesterday, .thisWeek, .lastWeek, .thisMonth, .lastMonth, .earlier, .unknown]
    }

    static func group(for date: Date?, calendar: Calendar = .current) -> SessionTimeGroup {
        guard let date else { return .unknown }
        let now = Date()

        if calendar.isDateInToday(date) {
            return .today
        }

        if calendar.isDateInYesterday(date) {
            return .yesterday
        }

        if let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now), currentWeek.contains(date) {
            return .thisWeek
        }

        if let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now),
           let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeek.start),
           let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastWeekStart),
           lastWeek.contains(date) {
            return .lastWeek
        }

        if let currentMonth = calendar.dateInterval(of: .month, for: now), currentMonth.contains(date) {
            return .thisMonth
        }

        if let currentMonth = calendar.dateInterval(of: .month, for: now),
           let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: currentMonth.start),
           let lastMonth = calendar.dateInterval(of: .month, for: lastMonthStart),
           lastMonth.contains(date) {
            return .lastMonth
        }

        return .earlier
    }
}

private struct SessionRow: View {
    let title: String
    let lastMessage: String?
    let cwd: String?
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            // Activity indicator
            Circle()
                .fill(isActive ? healthyGreen : Color(.systemGray4))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if let preview = lastMessage, !preview.isEmpty {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                
                if let cwd = cwd {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.caption2)
                        Text(cwd)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SessionCardStyle())
    }
}

private struct SessionCardStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(colorScheme == .dark ? Color(.secondarySystemBackground) : Color.white)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0 : 0.05), radius: 10, y: 6)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color(.systemGray5).opacity(colorScheme == .dark ? 0.4 : 1), lineWidth: colorScheme == .dark ? 0.5 : 1)
            )
    }
}

private struct NewSessionSheet: View {
    @Binding var workingDirectory: String
    let usedWorkingDirectories: [String]
    let onCancel: () -> Void
    let onCreate: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Working directory", text: $workingDirectory)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .font(.body.monospaced())
                } header: {
                    Text("Working Directory")
                } footer: {
                    Text("The directory where the agent will operate for this session.")
                }

                let trimmedCurrent = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                let history = usedWorkingDirectories.filter { $0 != trimmedCurrent }
                if !history.isEmpty {
                    Section {
                        ForEach(history, id: \.self) { directory in
                            Button {
                                workingDirectory = directory
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                    Text(directory)
                                        .font(.body.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Previously Used")
                    } footer: {
                        Text("Tap to fill the working directory.")
                    }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: onCreate)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct DeveloperLogsView: View {
    @ObservedObject var model: AppViewModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.updates.isEmpty {
                    ContentUnavailableView(
                        "No Logs",
                        systemImage: "doc.plaintext",
                        description: Text("Requests and responses will appear here while you interact with the agent.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.updates) { update in
                            DeveloperLogRow(log: update)
                                .id(update.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: model.updates) { _, newValue in
                guard let last = newValue.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = model.updates.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .navigationTitle("Server Logs")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }
}

private struct DeveloperLogRow: View {
    let log: LogLine
    @State private var isExpanded = false
    @Environment(\.colorScheme) private var colorScheme

    private var expandedDetails: String? {
        log.prettyDetails ?? log.details
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let details = expandedDetails {
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
                    Text(details)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } else {
                Text(log.message)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(log.title.isEmpty ? "Log Entry" : log.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let details = log.details {
                        Text(details)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer(minLength: 8)

                Text(log.timestampLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark ? Color(.secondarySystemBackground) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.systemGray5).opacity(colorScheme == .dark ? 0.4 : 1), lineWidth: colorScheme == .dark ? 0.5 : 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0 : 0.04), radius: 8, y: 4)
    }
}

private enum NavigationDestination: Hashable {
    case session(String)
    case developerLogs
}

extension View {
    func sessionCardStyle() -> some View {
        self.modifier(SessionCardStyle())
    }
}

/// A simple flow layout that wraps items horizontally.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .init(frame.size))
        }
    }
    
    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            
            frames.append(CGRect(x: currentX, y: currentY, width: size.width, height: size.height))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }
        
        return (CGSize(width: totalWidth, height: currentY + lineHeight), frames)
    }
}

#Preview {
    ContentView()
}
