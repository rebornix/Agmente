# ACPClient Plan

Protocol definition: https://agentclientprotocol.com/overview/introduction (ACP overview/spec).

## Goals
- Swift Package that handles ACP client responsibilities: connect/authenticate, send/receive ACP messages, maintain connection health.
- Clean separations for networking, models, configuration, and logging to allow testing and reuse in the iOS app.

## Package layout
- `Sources/ACPClient/` — public facade and core implementation (connection manager, router, heartbeat/backoff, auth header handling).
- `Sources/ACPClient/Models/` — Codable ACP types (agents, messages, errors) mapped from the spec.
- `Sources/ACPClient/Support/` — shared utilities: logging protocol, clock/timers, configuration, WebSocket abstraction.
- `Sources/ACPClientMocks/` — fakes/mocks for tests and app previews (fake socket, fake clock, dummy token provider).
- `Tests/ACPClientTests/` — unit tests + fixtures (encode/decode, connection lifecycle, reconnection/backoff, heartbeat, error paths).

## Implementation roadmap
1) Model mapping: define Swift Codable models for ACP messages/events per spec; add fixtures in `Tests/ACPClientTests/Fixtures`.
2) WebSocket abstraction: protocol `WebSocketProviding` + concrete URLSession-based implementation; expose `WebSocketConnection` events (connected, text, binary, closed).
3) Client facade: `ACPClient` init with configuration/logger/token provider; connect/disconnect; send message API; delegate/callback for state + incoming messages.
4) Auth & headers: async token provider hook; build headers per spec; allow additional headers.
5) Health: optional heartbeat/ping; backoff + retry on disconnect/error; surface state transitions.
6) Logging & metrics hooks: pluggable `ACPLogger`; lightweight event logging.
7) Tests: mock socket/clock; cover encoding/decoding, connect/send/receive flow, reconnection, heartbeat, error handling; add snapshot JSON fixtures.

## Integration notes
- Add this package locally in Xcode: File > Add Packages… > Add Local, select `Agmente/ACPClient`; link product `ACPClient` to the iOS app target.
- Set minimum platform to iOS 17 (already in `Package.swift`).
