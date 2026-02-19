# Agmente App Layer Guide

## Scope
SwiftUI app layer and protocol routing logic:
- Server management UI
- Session/thread UI state
- ACP vs Codex view model selection

## Architecture Model
- The app has a single coordinator that owns per-server runtime state.
- Each server runtime follows one protocol mode at a time (ACP or Codex).
- Protocol-specific behavior stays isolated behind a shared server view-model contract.
- UI should rely on shared abstractions first, and branch only for protocol-specific screens/controls.

## Architecture Invariants
- `AppViewModel` owns one server view model per server ID.
- ACP and Codex paths must remain protocol-isolated.
- UI should consume unified protocol (`ServerViewModelProtocol`) where possible.
- Session/thread summaries should preserve server metadata (`cwd`, timestamps) when available.
- Codex reconnect/resume must be non-destructive for active sessions: prefer richer in-memory chat/tool-call state when `thread/resume` is incomplete, and restore streaming/stop state from active turn status.
- On reconnect (and open when possible), prefer non-destructive reattachment to loaded in-memory threads via `addConversationListener` + `thread/read`; only fall back to `thread/resume` when the thread is not loaded or listener attach is unavailable.
- For resume-based hydration paths, issue at least one follow-up `thread/resume` to converge eventual-consistency gaps where streaming deltas are not replayed.
- Use `persistExtendedHistory: true` on `thread/start` and `thread/resume` so cold app relaunch can recover richer tool-call history from rollout-backed reads.
- Plan mode output must map to `.plan` assistant segments from Codex notifications (`item/plan/delta`, `turn/plan/updated`) and from completed assistant message payloads containing `<proposed_plan>...</proposed_plan>`.
- For plan streaming, prefer typed app-server notifications (for example `item/plan/delta`) over mirrored raw `codex/event/*` notifications to avoid duplicate rendering.
- Codex permissions selector maps to `turn/start` overrides on every turn:
  - `Default permissions` => `approvalPolicy: "on-request"` + `sandboxPolicy.type: "workspaceWrite"`
  - `Full access` => `approvalPolicy: "never"` + `sandboxPolicy.type: "dangerFullAccess"` (dangerous/high-risk mode)

## Change Impact Rules
- Protocol detection changes must validate both first-connect and reconnect behavior.
- Session/thread list parsing changes must preserve ordering and metadata consistency.
- Open-session behavior must not regress summary metadata or current working directory display.
- Reconnect/background-resume changes must verify active-thread resubscription, streaming indicator state, and stop/send button behavior.
- Add-server form or summary dialog changes must keep ACP and Codex messaging clearly separated.

## Contribution Checklist
- If changing initialization/protocol detection, validate ACP and Codex paths.
- If changing session/thread metadata parsing, verify list + open-session behavior.
- If changing add-server UX, verify both protocol summaries and warnings are accurate.
- If adding capability toggles/settings, persist and restore via existing model/storage patterns.

## Required Tests
- `CodexServerViewModelTests`
- `ViewModelSyncTests`
- `ACPSessionViewModelTests` (when chat/session behavior changes)
- Relevant `AgmenteUITests` coverage (when UI flow or accessibility IDs change)
