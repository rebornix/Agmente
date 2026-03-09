# AppServer Maintenance Notes

## Scope
This note documents the final Codex thread hydration strategy used by Agmente for:
- session open
- reconnect resubscription
- history merge behavior

## Problem We Solved
Using `thread/resume` as the primary reconnect/open path caused unstable UX:
- duplicate assistant/tool rows after reconnect/open
- partial history during live turns
- weaker live streaming continuity after reconnect

## Final Strategy (Keep This)

### 1) Prefer non-destructive attach when possible
For session open and reconnect:
1. call `thread/loaded/list`
2. if target thread is loaded:
   - call `addConversationListener`
   - call `thread/read` with `includeTurns: true`
3. merge snapshot into local chat state

Reason: this preserves the active in-memory thread and avoids destructive replacement.

### 2) Fallback to `thread/resume` only when needed
Use `thread/resume` only if:
- the thread is not loaded in memory, or
- listener attach/read path is unavailable

Reason: `thread/resume` reconstructs from rollout and can replace the in-memory thread object.
If `thread/resume` reports an in-progress turn, treat that as resume-derived state until a loaded-thread attach/read or a live turn notification confirms the turn is still active. In Agmente this means the composer should allow a local reset instead of immediately sending `turn/interrupt`.

### 3) Merge policy
When merging hydrated data into local chat:
- preserve richer local tool-call rows/outputs
- append newly resumed items from server
- avoid duplicate assistant text by normalized text/ID-aware matching

### 4) Persistence for cold relaunch
Send `persistExtendedHistory: true` on:
- `thread/start`
- `thread/resume`

Reason: improves rollout history fidelity for full app relaunch recovery.

## Known Limits
- `persistExtendedHistory` does not backfill old threads.
- Some streaming deltas are intentionally not persisted server-side; snapshot reads are still eventually-consistent views.

## Maintenance Guardrails
- Do not reintroduce unconditional `thread/resume` on reconnect.
- Do not run immediate extra resume after successful listener+read attach.
- Keep `includeTurns: true` for `thread/read` hydration paths.
- If changing merge logic, verify:
  - no duplicate assistant/tool rows
  - no loss of local rich tool output
  - new resumed items still append in correct order

## Regression Checks
- Background/foreground reconnect during an active multi-step turn:
  - live streaming must continue
  - no duplicated initial assistant block
- Full app quit + relaunch + reopen session:
  - history should restore from snapshot
  - new threads (created after persistence change) should include richer tool-call history
