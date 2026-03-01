# E2E Scenarios

This directory holds repository-owned end-to-end specs for Agmente.

## Purpose
- Make E2E requests agent-agnostic.
- Keep scenario behavior in the repo instead of in skill instructions.
- Let contributors add new prompt/spec tests without copying backend commands or assertion text into every file.

## Directory Layout
- `backends/`: reusable backend definitions
- `scenarios/`: user-facing test specs
- `assertions/`: shared assertion vocabulary
- `schema/`: front matter and structure contract

## Dependency Direction
- Scenarios may reference backends and shared assertions.
- Skills may read scenarios and backends to execute them.
- Scenarios must not reference skills.

## Execution Modes
- `run`, `execute`, `validate`, and `reproduce` mean agentic execution only.
- Agentic execution means the agent should actually start the backend, drive the simulator or other required tools, capture logs and screenshots when relevant, evaluate the scenario assertions, and perform cleanup.
- Execute-only runs must not modify repository files, add hooks, write tests, or patch docs while trying to make the scenario pass.
- If an execute-only run is blocked by missing automation affordances, missing accessibility identifiers, unstable tools, or unclear state, report the blocker and stop.
- `fix`, `stabilize`, `make executable`, `add hooks`, and similar requests explicitly allow repository changes.

## Authoring Rules
1. Add or reuse a backend in `e2e/backends/`.
2. Add a scenario in `e2e/scenarios/<protocol>/`.
3. Use the front matter shape from `e2e/schema/scenario-frontmatter.md`.
4. Reuse shared wording from `e2e/assertions/common.md` instead of copying expectations into many files.
5. Keep tool-specific execution details out of the scenario unless they are part of the product behavior under test.

## Running Scenarios
Agents should resolve scenario specs from `e2e/scenarios/` first, then optionally use `.agents/skills/` or scripts to execute them.

When the user asks to run a scenario, prefer actual end-to-end execution over describing manual steps. Only switch from execution to implementation work if the user explicitly asks for a fix.

Example user requests:
- `Run the ACP custom cwd scenario`
- `Execute e2e/scenarios/acp/copilot-smoke.md and report failures`
- `Run the Codex local CLI smoke scenario against an existing app-server`

## Shared Conventions
- Prefer Markdown with front matter.
- Use `backend` for one backend and `backends` for a compatible matrix.
- Write expectations in protocol and UI terms, not in terms of a particular MCP tool.
- Put reusable launch and cleanup commands in backend files, not repeated in scenarios.
