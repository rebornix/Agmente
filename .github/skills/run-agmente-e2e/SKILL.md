---
name: run-agmente-e2e
description: Run Agmente iOS end-to-end tests against a local ACP agent (Gemini, Claude, Qwen, or Vibe), validate core RPC flow, and perform mandatory cleanup.
---

# Run Agmente E2E

Use this skill when the user asks to run Agmente E2E or UI-level integration checks with a real ACP agent.

## Inputs

- `agent`: `gemini` (default), `claude`, `qwen`, or `vibe`
- `scenario`: `sanity` (default), `add-server`, `prompt-send`
- `port`: default `9000`
- `simulatorID`: default `BE205EA8-B26C-44C2-B52B-B49141678273`
- `npxTag`: package tag for npx-based agents (`latest` by default). Override via third arg to `start_agent.sh` or `AGMENTE_E2E_NPX_TAG`.

## Workflow

1. Start local ACP bridge in background:
   - `./.github/skills/run-agmente-e2e/scripts/start_agent.sh <agent> <port>`
2. Build and run in simulator:
   - Use XcodeBuildMCP `build_run_sim` with Agmente defaults.
3. Execute UI steps:
   - Follow `references/ui-checklist.md`.
   - Call `describe_ui` before each tap.
   - Use tap by `id` or `label` where available.
4. Validate protocol behavior:
   - Confirm sequence: `initialize` -> `session/list` -> `session/new` -> `session/prompt`.
   - Confirm capability badges and session list behavior.
5. Cleanup always (success or failure):
   - `./.github/skills/run-agmente-e2e/scripts/cleanup.sh <simulatorID> <port>`

## Constraints

- Do not skip cleanup.
- Use a valid working directory on host machine (for Agmente server config).
- Do not rely on guessed coordinates from screenshots.
- Prefer deterministic selectors and `describe_ui`.

## References

- UI and validation checklist: `references/ui-checklist.md`
