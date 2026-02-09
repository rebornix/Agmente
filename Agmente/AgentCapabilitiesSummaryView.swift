import SwiftUI
import ACPClient

// Note: CodexServerSummary removed - app-server protocol doesn't provide modes or capabilities.
// Codex servers show only the "Codex" badge in the stats row.

// MARK: - ACP Capabilities Summary

struct AgentCapabilitiesSummary: View {
    let capabilities: AgentCapabilityState
    let verifications: [AgentCapabilityVerification]

    private var features: [(feature: String, icon: String, label: String, enabled: Bool)] {
        [
            ("listSessions", "list.bullet", "List", capabilities.listSessions),
            ("promptCapabilities.image", "photo", "Image", capabilities.promptCapabilities.image),
            ("promptCapabilities.audio", "waveform", "Audio", capabilities.promptCapabilities.audio),
            ("promptCapabilities.embeddedContext", "doc.text", "Context", capabilities.promptCapabilities.embeddedContext),
            ("loadSession", "arrow.clockwise", "Restore", capabilities.loadSession),
            ("resumeSession", "arrow.trianglehead.clockwise", "Resume", capabilities.resumeSession)
        ]
    }

    private var verificationWarnings: [(label: String, title: String, details: String)] {
        features.compactMap { feature -> (label: String, title: String, details: String)? in
            guard feature.enabled,
                  let verification = verifications.first(where: { $0.feature == feature.feature && $0.outcome == .warning }) else {
                return nil
            }
            return (
                label: feature.label,
                title: "\(feature.label) support may be unreliable",
                details: verification.details
            )
        }
    }

    private var sessionSupportWarnings: [(title: String, details: String)] {
        let missingList = !capabilities.listSessions
        let missingLoad = !capabilities.loadSession
        let hasResume = capabilities.resumeSession
        switch (missingList, missingLoad, hasResume) {
        case (false, false, _):
            return []
        case (true, true, true):
            return [(
                title: "Limited session recovery",
                details: "This agent supports `session/resume` but not `session/list` or `session/load`. Agmente keeps sessions and chat history locally, and will reattach sessions via `session/resume` after app restart, but full server-side history replay isn’t available."
            )]
        case (true, true, false):
            return [(
                title: "Limited session recovery",
                details: "This agent supports neither `session/list` nor `session/load`. Agmente keeps sessions and chat history locally, but if the agent restarts, older sessions may stop working."
            )]
        case (true, false, _):
            return [(
                title: "`session/list` not supported",
                details: "Agmente keeps a local session list so sessions still show up after app restart. If the agent restarts and forgets sessions, older sessions may stop working."
            )]
        case (false, true, true):
            return [(
                title: "`session/load` not supported",
                details: "Agmente stores chat history locally. The agent can reattach to existing sessions via `session/resume`, but only if it still remembers the session; if the agent/server restarts, reattach may fail and full transcript replay isn’t available."
            )]
        case (false, true, false):
            return [(
                title: "`session/load` not supported",
                details: "Agmente stores chat history locally so you can browse sessions and past conversations, but the agent can’t restore context for new messages. If the agent/server restarts, old session IDs may stop working."
            )]
        }
    }

    private var warningLabels: Set<String> {
        Set(verificationWarnings.map(\.label))
    }

    private var badges: [(feature: String, icon: String, label: String, enabled: Bool)] {
        features.filter { feature in
            feature.enabled && !warningLabels.contains(feature.label)
        }
    }

    private var warnings: [(title: String, details: String)] {
        verificationWarnings.map { (title: $0.title, details: $0.details) } + sessionSupportWarnings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !badges.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(badges, id: \.label) { badge in
                        HStack(spacing: 4) {
                            Image(systemName: badge.icon)
                                .font(.caption2)
                            Text(badge.label)
                                .font(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(.systemGray5))
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { warning in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(warning.element.title)
                                    .font(.caption.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(warning.element.details)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.systemGray6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                        )
                    }
                }
            }
        }
    }
}