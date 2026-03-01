# Agmente Cloud Agent Guide

This file is the entrypoint for cloud/Claude coding agents. Use it with `Agents.md`.

## Read Order
1. `Agents.md` (root policy and protocol overview)
2. Component docs closest to changed code:
   - `Agmente/AGENTS.md`
   - `ACPClient/AGENTS.md`
   - `AppServerClient/AGENTS.md`
   - `AgmenteTests/AGENTS.md`
   - `AgmenteUITests/AGENTS.md`
   - `e2e/AGENTS.md`

## Local Path Config
- Use root `.agmente.paths` for machine-local external repo paths.
- Required vars: `AGMENTE_ACP_REPO`, `AGMENTE_CODEX_REPO`.
- Read this file when running upstream-spec/source checks.

## Core Architecture
- Agmente supports two protocol modes: ACP and Codex app-server.
- Protocol is detected after `initialize` and routed to protocol-specific view models.
- Keep ACP and Codex behaviors separate unless a shared abstraction is intentional and tested.

## Contribution Rules
- Prefer component-local changes; avoid cross-cutting refactors unless needed.
- Do not add personal local filesystem paths to tracked files.
- If behavior differs by protocol, document both expected paths.
- For UI changes, keep accessibility identifiers stable or update UI tests in the same PR.

## Documentation Rules
- Update `Agents.md` and this file in the same PR when:
  - adding a new top-level component,
  - adding protocol support,
  - changing cross-component architecture.
- Update nested `<component>/AGENTS.md` in the same PR when behavior in that component changes.
- If no docs are needed, include `Docs: N/A` in PR notes.

## Testing Expectations
- Run focused tests for touched components first.
- For protocol lifecycle changes, run both:
  - `AgmenteTests/CodexServerViewModelTests`
  - `AgmenteTests/ViewModelSyncTests`
- For UI flow or accessibility changes, run relevant `AgmenteUITests`.
- Codex E2E remains opt-in via environment configuration (see `AgmenteUITests/AGENTS.md`).
- For manual or simulator E2E requests, resolve the scenario from `e2e/scenarios/` before consulting any skill.
- Treat `run`, `execute`, `validate`, and `reproduce` E2E requests as execute-only and agentic: run the real backend and tools, capture evidence, evaluate assertions, and clean up.
- Do not modify repo files during an execute-only E2E run unless the user explicitly asks to fix, stabilize, add hooks, or make the scenario executable.
