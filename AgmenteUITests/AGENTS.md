# Agmente UI Tests Guide

## Scope
Simulator-driven UI tests, including scenario-backed manual E2E and opt-in Codex local E2E.

## External Repo Paths
- Use root `.agmente.paths` for machine-local ACP/Codex checkout locations when debugging upstream compatibility.
- Read it as the source of truth; do not hard-code local absolute paths.

## Coverage Goals
- Add-server flows for ACP and Codex.
- Connect/initialize/session lifecycle UX.
- Prompt send/stream/render experience.
- Accessibility-id stability for critical controls.

## Codex E2E Contract
- E2E test is opt-in and environment-driven.
- Scenario intent lives under `e2e/scenarios/codex/`; the env vars below are the UI-test harness contract, not the source of truth for scenario behavior.
- Supported env keys:
  - `AGMENTE_E2E_CODEX_ENABLED`
  - `AGMENTE_E2E_CODEX_ENDPOINT`
  - `AGMENTE_E2E_CODEX_HOST`
  - `AGMENTE_E2E_CODEX_PROMPT`
  - `AGMENTE_E2E_CODEX_CONFIG_PATH`
- Do not hard-code developer-specific endpoints or filesystem paths in tests.

## UI Automation Rules
- Prefer accessibility IDs over coordinate taps.
- If adding/changing critical controls, add stable accessibility IDs in app code.
- Keep ACP and Codex add-server flows separately validated.
- Keep test assertions tied to behavior, not layout coordinates.

## Cleanup Expectations
After simulator E2E runs:
1. Stop local agent/app-server process.
2. Uninstall app from simulator to reset state.
