---
name: codex-local-cli-e2e
description: Run and debug Agmente iOS end-to-end tests against a real local Codex CLI app-server instance. Use when validating Codex websocket/protocol compatibility, connect/initialize/thread flows, or reproducing Codex-only UI test failures with an actual local Codex server.
---

# Codex Local CLI E2E

## Overview

Run Agmente's Codex UI E2E test against a real local `codex app-server`, using the repo-owned scenario spec as the source of truth, collect actionable failure details, and always clean up simulator/app-server state.

## Workflow

1. Resolve run inputs.
- Require `endpoint` (for example `ws://127.0.0.1:8788`) and simulator `UDID`.
- Decide run mode:
  - `existing server`: server already running.
  - `managed server`: start server with a provided command and stop it during cleanup.
- Read `e2e/scenarios/codex/local-cli-smoke.md`.
- Use `references/agmente-codex-e2e-contract.md` only for the UI-test environment-variable harness contract.

2. Start or verify server.
- If `managed server`, start the command and wait until the endpoint port is reachable.
- If `existing server`, verify reachability before running tests.

3. Run only the Codex UI E2E test.
- Export:
  - `AGMENTE_E2E_CODEX_ENABLED=1`
  - `AGMENTE_E2E_CODEX_ENDPOINT=<endpoint>`
- Execute targeted test only:
  - `AgmenteUITests/AgmenteUITests/testCodexDirectWebSocketConnectInitializeAndSessionFlow`

4. On failure, extract root cause.
- Parse `xcodebuild` output for the failing test and assertion.
- Read `.xcresult` details when `xcodebuild` is not explicit.
- Include failing file/line and endpoint/simulator context in the report.

5. Always clean up.
- Stop app-server if this run started it.
- Uninstall app from simulator:
  - `xcrun simctl uninstall <UDID> com.example.Agmente`
- Optionally shut simulator down if requested.

## Preferred Execution

Use the bundled script for deterministic runs:
- `scripts/run_codex_local_e2e.sh`

Managed-server example:

```bash
scripts/run_codex_local_e2e.sh \
  --endpoint ws://127.0.0.1:8788 \
  --udid <SIMULATOR_UDID> \
  --start-codex-cmd "codex app-server --listen ws://127.0.0.1:8788"
```

Existing-server example:

```bash
scripts/run_codex_local_e2e.sh \
  --endpoint ws://127.0.0.1:8788 \
  --udid <SIMULATOR_UDID>
```

## Reporting Requirements

Always report:
- Endpoint used.
- Simulator UDID used.
- Pass/fail status.
- Failing assertion and file/line (if failed).
- Paths to `xcodebuild` log and Codex server log.
