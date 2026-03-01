---
name: acp-local-runner
description: Run and debug Agmente ACP end-to-end scenarios from the repo-owned e2e/scenarios/acp specs. Use when validating ACP websocket compatibility, session creation, cwd handling, reconnect flows, or reproducing ACP-only UI failures against a real local ACP backend.
---

# ACP Local Runner

## Overview

Execute a repo-owned ACP scenario against a real local ACP backend, capture enough logs and UI state to diagnose failures, and always clean up backend and simulator app state.

For `run`, `execute`, `validate`, or `reproduce` requests, this skill is execute-only. Use real tools to perform the scenario; do not modify repository files unless the user explicitly asks to fix, stabilize, or make the flow executable.

## Workflow

1. Resolve the scenario.
- Read the requested scenario from `e2e/scenarios/acp/`.
- If the user names no scenario, choose the closest match from that directory and state the choice.
- Treat the scenario file as the source of truth for setup, steps, assertions, and cleanup intent.

2. Resolve the backend.
- Read the backend id from the scenario front matter.
- Open the matching file in `e2e/backends/`.
- Use the backend file for canonical endpoint, start command, stop command, and capability notes.

3. Prepare execution.
- Prefer simulator execution when the scenario target is `ios-simulator`.
- Use XcodeBuildMCP tools when available for boot/build/run/log/screenshot/interaction.
- If simulator interaction tools are incomplete, use the best available non-editing fallback and state the limitation.
- Verify the backend is reachable before debugging app behavior.

4. Run the scenario.
- Follow the scenario steps in order.
- Capture wire or console checkpoints around `initialize`, `session/list`, `session/new`, `session/prompt`, `session/load`, and reconnect events when relevant.
- Use the scenario assertions and `e2e/assertions/common.md` to judge pass/fail.

5. Report and clean up.
- Report backend, endpoint, simulator target, scenario path, and pass/fail status.
- On failure, report the concrete broken step and the most likely root cause.
- Always stop the backend if this run started it.
- Always uninstall Agmente from the simulator unless the user explicitly asks to preserve state.

## Guardrails

- Do not invent ACP behavior that is not in the scenario or backend docs.
- Do not make the skill the source of truth for scenario semantics.
- Prefer protocol-level explanations over tool-level explanations in failure reports.
- If the scenario and backend docs disagree, treat that as repo drift and report it.
- Treat `run`, `execute`, `validate`, and `reproduce` as execute-only requests.
- Agentic testing means actually running the backend, simulator, and relevant protocol tooling rather than describing manual steps.
- During execute-only runs, do not add accessibility identifiers, write harness code, patch docs, or create new tests to make the scenario pass.
- If the run is blocked by missing automation hooks or incomplete tooling, report the blocker and stop instead of editing the repo.
- Only make repository changes when the user explicitly asks to fix, stabilize, add hooks, or make the scenario executable.
