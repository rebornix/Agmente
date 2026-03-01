# Agmente E2E Scenarios Guide

## Scope
Repository-owned end-to-end scenario specifications, reusable backend definitions, shared assertions, and contribution rules for simulator/manual protocol validation.

## Ownership Boundaries
- `e2e/scenarios/` is the source of truth for user-facing E2E intent.
- `e2e/backends/` defines reusable backend launch/config metadata.
- `e2e/assertions/` defines shared assertion vocabulary to avoid restating expectations.
- `e2e/schema/` documents required front matter and section structure.
- `.agents/skills/` may help execute scenarios, but scenarios must not depend on a specific skill.

## Architecture Rules
- Prefer Markdown with front matter for scenarios and backends.
- Scenario files should contain only scenario-specific behavior.
- Shared launch commands, cleanup commands, and assertion wording belong in reusable docs, not copied into every scenario.
- Skills may read scenarios to decide execution steps, but scenario files must stay valid and useful without any skill system.
- `run`, `execute`, `validate`, and `reproduce` requests are execute-only unless the user explicitly asks to fix or stabilize the scenario.
- Execute-only means agentic testing: use real backends, simulator or protocol tools, logs, assertions, and cleanup instead of proposing code changes.
- During execute-only runs, do not edit app code, add automation hooks, write new tests, or patch docs to work around blockers.
- If execution is blocked by missing affordances or incomplete tooling, report the concrete blocker and stop.

## Contribution Checklist
- Reuse an existing backend in `e2e/backends/` before adding a new one.
- Reuse shared assertion names from `e2e/assertions/common.md` where possible.
- Keep setup/steps/assertions/cleanup in scenario files concise and behavior-focused.
- Update `Agents.md` and `CLAUDE.md` when changing the top-level `e2e/` contract.
- Update this file when changing scenario structure, backend references, or contribution rules.

## Required Sections
- Front matter with scenario identity and backend/target metadata.
- `# Setup`
- `# Steps`
- `# Assertions`
- `# Cleanup`

## Compatibility Notes
- ACP scenarios should describe `session/new`, `session/prompt`, `session/load`, and cwd expectations in protocol terms, not tool terms.
- Codex scenarios should describe `thread/start`, `thread/resume`, and turn expectations in protocol terms, not tool terms.
- Simulator automation guidance belongs in skills or test harness docs, unless it is a scenario-specific precondition.
