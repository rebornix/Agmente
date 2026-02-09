# ACPClient Implementation Plan (iOS)

Reference docs: local `Docs/` (copied from agent-client-protocol/docs). Core spec pages: `Docs/overview/introduction.mdx`, `Docs/protocol/transports.mdx`, schema under `Docs/schema`.

## Transport choice (iOS)
- Primary: JSON-RPC over WebSocket (best iOS fit for bidirectional streaming; stdio is impractical on iOS). Treat WebSocket as a custom transport while preserving JSON-RPC framing/lifecycle.
- Pluggable transport protocol so Streamable HTTP (draft) or other custom transports can be swapped in later.

## Architecture
- `Transport` abstraction: `connect(headers:)`, `send(text:)`, `receive()` -> events (`connected`, `text`, `closed(reason)`, `error`).
- WebSocket transport: `URLSessionWebSocketTask` based; handles backoff/retry, ping/pong/heartbeat, graceful close, max message size, timeout.
- JSON-RPC codec: envelope types (Request/Notification/Response/Error), ids (string/int), encode/decode, `$/cancelRequest` support.
- ACP models: map schema (initialization, session setup/modes, prompt turn, tool calls, file system, terminals, slash commands, agent plan, content). Use Codable and fixtures from `Docs` examples.
- Client facade: `ACPClient` with config (endpoint, headers, token provider, timeouts, ping interval, reconnection policy), delegate/callbacks for state + inbound messages/errors; send APIs for request/notify.
- Auth: async token provider builds Bearer header (or custom); merges additional headers.
- Health: heartbeat/ping, backoff with jitter and caps, retryable vs terminal errors surfaced; close semantics.
- Logging: protocol + `NoOp` / `PrintLogger`; hooks for metrics if needed.

## Testing
- Mock transport (scripted receive queue), fake clock/backoff timers, deterministic ids.
- JSON fixtures from `Docs` for encode/decode; cover connect/send/receive, reconnection, heartbeat, cancellation, error propagation.
- Mocks target (`ACPClientMocks`) for app previews and unit tests.

## Phased implementation
1) Define transport protocol + WebSocket implementation + config/logging; basic state machine.
2) JSON-RPC codec and ACP model mapping to schema; sample fixtures.
3) Client facade wiring: connect/disconnect, send/receive pipeline, delegate callbacks, auth headers.
4) Reliability: heartbeat/ping, reconnection/backoff, close handling, cancellation (`$/cancelRequest`).
5) Tests and sample usage in the app target (SwiftUI view model using ACPClient).

## Integration notes
- Swift Package targets: `ACPClient`, `ACPClientMocks` (test/previews). Minimum iOS 17 (set in Package.swift).
- In Xcode: add local package (`Agmente/ACPClient`), link `ACPClient` to app target.
- App: SwiftUI view model wraps `ACPClient`; Keychain for tokens, UserDefaults/CoreData for agent lists/history.
