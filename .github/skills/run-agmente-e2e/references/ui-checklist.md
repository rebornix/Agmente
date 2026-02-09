# UI Checklist

## Setup

1. Start agent bridge:
   - `scripts/start_agent.sh <agent> 9000 latest`
2. Build and run Agmente on simulator.

## Sanity Scenario

1. Add server:
   - Tap `Add Server`.
   - Name: any value.
   - Protocol: `ws`.
   - Host: `localhost:9000`.
  - Working directory: `/path/to/your/workspace`.
2. Save and connect:
   - Tap `Save Server`.
   - Review capabilities.
   - Tap `Acknowledge and Add`.
3. Create session:
   - Tap `New Session`.
4. Send prompt:
   - Tap message input.
   - Type prompt text.
   - Tap send button.

## Validation

- Capability badges appear (Image / Audio / Context when supported).
- If `session/list` unsupported, warning is shown.
- Session appears in sidebar (for example `1 idle`).
- RPC sequence observed:
  - `initialize`
  - `session/list`
  - `session/new`
  - `session/prompt`

## Tooling Rules

- Use `describe_ui` before each tap.
- Prefer tap by `id` or `label`.
- Use `postDelay` instead of arbitrary sleeps.
- Capture screenshots at key checkpoints.

## Result Table

| Test | Status | Notes |
| --- | --- | --- |
| Agent server started | ✅/❌ | |
| App built and launched | ✅/❌ | |
| Server added | ✅/❌ | |
| Session created | ✅/❌ | |
| Message sent | ✅/❌ | |
| Cleanup completed | ✅/❌ | |

## Cleanup (always)

- `scripts/cleanup.sh <SIMULATOR_UUID> 9000`
