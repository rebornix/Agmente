# UI Checklist (Codex App-Server)

## Setup

1. Start Codex bridge:
   - `scripts/start_codex.sh "codex app-server" 9000 latest`
2. Build and run Agmente on simulator.

## Sanity Scenario

1. Add server:
   - Tap `Add Server`.
   - Name: any value.
   - Server Type: `Codex App-Server`.
   - Protocol: `ws`.
   - Host: `localhost:9000`.
  - Working directory: `/path/to/your/workspace`.
2. Save and connect:
   - Tap `Save Server`.
3. Create session:
   - Tap `New Session`.
4. Send turn:
   - Tap message input.
   - Type prompt text.
   - Tap send button.

## Validation

- Server connects and Codex session view is shown.
- Model/mode metadata appears if provided by `thread/start` response.
- Prompt/turn returns output in chat.
- RPC sequence observed:
  - `initialize`
  - `initialized` notification
  - `thread/list`
  - `thread/start` (or `thread/resume`)
  - `turn/start`
  - `turn/started`
  - `turn/completed`
- Streaming notifications observed:
  - `item/*` and/or `codex/event/*`

## Tooling Rules

- Use `describe_ui` before every tap.
- Prefer tap by `id` or `label`.
- Use `postDelay` instead of arbitrary sleeps.
- Capture `screenshot` at key checkpoints.

## Result Table

| Test | Status | Notes |
| --- | --- | --- |
| Codex bridge started | ✅/❌ | |
| App built and launched | ✅/❌ | |
| Codex server added | ✅/❌ | |
| Thread created | ✅/❌ | |
| Turn sent | ✅/❌ | |
| Codex RPC sequence verified | ✅/❌ | |
| Cleanup completed | ✅/❌ | |

## Cleanup (always)

- `scripts/cleanup.sh <SIMULATOR_UUID> 9000`
