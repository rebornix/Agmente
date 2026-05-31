# ACPClient Package Guide

## Scope
Typed ACP transport/service package used by the iOS app.

## External Repo Paths
- Read `.agmente.paths` (from repo root) before cross-checking ACP upstream docs/spec.
- ACP upstream reference root: `AGMENTE_ACP_REPO/docs`.

## Architecture Model
- Transport concerns, request orchestration, and ACP parsing are separated layers.
- Public service APIs should remain typed and hide wire-format details from callers.
- Parsing helpers should be resilient to optional/partial ACP payloads.

## Extension Pattern
When adding ACP method support:
1. Add the method constant and typed payload mapping.
2. Expose a typed service wrapper.
3. Add response/event parsing coverage.
4. Ensure delegate and pending-request behavior remain correct.
5. Add package tests for success and failure paths.
- Optional ACP methods currently supported include `logout`, `session/list`,
  `session/load`, `session/resume`, `session/close`, `session/set_mode`, and
  `session/set_config_option`; keep capability parsing and `-32601` fallback
  behavior in sync when adding more optional methods.

## Compatibility Rules
- Preserve support for server-initiated JSON-RPC requests (do not treat as transport errors).
- Keep slash-escaping compatibility option functional.
- Keep request ID/pending continuation behavior deterministic.
- Keep reconnection/disconnect semantics from breaking in-flight request handling.

## Tests
- Run package tests for `ACPClient`.
