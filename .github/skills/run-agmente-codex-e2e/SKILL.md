---
name: run-agmente-codex-e2e
description: Run Agmente iOS end-to-end tests against a local Codex app-server endpoint, validate Codex thread/turn protocol flow, and perform mandatory cleanup.
---

# Run Agmente Codex App-Server E2E

Use this skill when the user asks to run Agmente E2E against OpenAI Codex app-server.

## Inputs

- `scenario`: `sanity` (default), `add-server`, `turn-send`
- `port`: default `9000`
- `simulatorID`: default `BE205EA8-B26C-44C2-B52B-B49141678273`
- `codexCommand`: default `codex app-server` (override via first arg to `start_codex.sh` or `CODEX_APP_SERVER_CMD`)
- `npxTag`: package tag for `@rebornix/stdio-to-ws` (`latest` by default, override via third arg or `AGMENTE_E2E_NPX_TAG`)

## Workflow

1. Start local Codex bridge in background:
   - `./.github/skills/run-agmente-codex-e2e/scripts/start_codex.sh "<codexCommand>" <port> <npxTag>`
2. Build and run in simulator:
   - Use XcodeBuildMCP `build_run_sim` with Agmente defaults.
3. Execute UI steps:
   - Follow `references/ui-checklist.md`.
   - Set server type to `Codex App-Server`.
   - Call `describe_ui` before each tap.
   - Prefer tap by `id` or `label`.
4. Validate protocol behavior from bridge logs:
   - Confirm sequence: `initialize` -> `initialized` -> `thread/list` -> `thread/start` -> `turn/start` -> `turn/started` -> `turn/completed`.
   - Confirm streamed notifications arrive (`item/*` and/or `codex/event/*`).
5. Cleanup always (success or failure):
   - `./.github/skills/run-agmente-codex-e2e/scripts/cleanup.sh <simulatorID> <port>`

## Constraints

- Do not skip cleanup.
- Use a valid host working directory (for example `/path/to/your/workspace`).
- Do not rely on guessed coordinates from screenshots.
- Prefer deterministic selectors and `describe_ui`.

## References

- UI and validation checklist: `references/ui-checklist.md`
