# Codex Load / Resume / Merge Spec

## Purpose
Define the behavioral contract for loading, resuming, and reconciling Codex threads in Agmente.

This spec is the source of truth for how the app hydrates thread state after open, reconnect, foregrounding, and eventual-consistency refreshes.

## Scope
This spec covers:
- thread hydration from Codex server state
- reconciliation between local in-memory transcript state and resumed server state
- preservation of rich assistant state during reconnect or stale resume conditions
- duplicate suppression and ordering guarantees
- follow-up refresh behavior after initial hydration

This spec does not cover:
- transport connection setup
- UI layout details
- ACP session lifecycle

## Design Intent
Codex hydration is non-destructive reconciliation, not overwrite.

The goal is to:
- preserve richer local transcript state when the server snapshot is incomplete
- ingest genuinely new remote items when they become available
- avoid duplicate assistant content
- keep transcript meaning stable across open and reconnect flows

This matters most for:
- in-flight turns
- tool-call rows
- reasoning and thought rows
- partial assistant output
- delayed final messages after backgrounding or reconnect

## Sources of Hydration
A thread may be hydrated from:
- loaded-thread reattachment plus `thread/read`
- `thread/resume`
- one or more follow-up `thread/resume` refreshes used to converge eventual consistency

Preferred behavior:
- use loaded-thread reattachment plus `thread/read` when possible
- fall back to `thread/resume` when reattachment is unavailable
- use follow-up refreshes after resume-based hydration when convergence may still be needed

## Core Invariants
- Hydration for an active thread must be non-destructive.
- Rich local assistant state must not be replaced by a poorer resumed snapshot.
- User-before-assistant ordering must remain stable after reconciliation.
- Tool-call, file-change, plan, reasoning, and streaming structure must be preserved when already present locally.
- Resume or read may add missing items, but must not flatten rich local structure into plain markdown-only assistant content.
- Duplicate assistant content must be suppressed when the same logical content is already represented by a richer local row.
- Resume-based hydration must allow eventual consistency to converge through follow-up refresh.

## Hydration Decision Flow
1. Obtain remote thread state from `thread/read` or `thread/resume`.
2. Determine whether the local thread appears to have an in-flight turn.
3. If the remote snapshot appears stale relative to local in-flight state, preserve local transcript state and skip destructive merge.
4. Otherwise, compare local richness against resumed richness.
5. If local state is richer, preserve local richness and merge in only genuinely new remote content.
6. If local state is not richer, merge resumed history normally.
7. If hydration was resume-based, schedule follow-up refresh as needed.

## Stale Snapshot Detection
A resumed snapshot is stale for the active thread when:
- local state indicates an in-flight turn, and
- the resumed snapshot does not report that active turn, or
- the resumed snapshot otherwise appears behind local streaming state

When a snapshot is stale:
- preserve local transcript state
- do not overwrite local assistant, thought, or tool-call rows
- keep current streaming state bound to the active turn
- schedule follow-up refresh so the thread can still converge when the server catches up

## Preserve-Local-Richness Rules
Local state is considered richer when it preserves transcript meaning that the resumed snapshot dropped.

Examples include:
- local transcript has more tool-call rows than resumed state
- local transcript has more assistant rows representing the same logical turn
- local transcript has tool outputs that resumed state omitted
- local transcript has thought or reasoning content that resumed state omitted
- local transcript contains a longer or more complete assistant progression while resumed state contains only an earlier prefix snapshot

When local state is richer:
- keep the richer local rows
- merge in new remote items that are not already represented locally
- do not downgrade a rich local assistant row into a shorter or flatter remote representation

## Duplicate Suppression Rules
A resumed assistant item should be suppressed when it is already represented by local state.

Representation may be established by:
- exact user or assistant content match
- assistant text already contained in a richer local assistant row
- thought or reasoning content already present in a richer local assistant row
- resumed tool-call identifiers being a subset of tool-call identifiers already represented locally

Duplicate suppression exists to prevent:
- duplicate assistant markdown rows
- duplicate thought rows after reconnect
- duplicate tool-related assistant summaries when a rich local row already contains the same content

## Ordering Rules
Reconciliation must preserve visible transcript meaning.

Required ordering guarantees:
- user input must remain before assistant output for the same conversational step
- when local rich rows are carried forward, they must be reinserted near their original conversational neighbors
- newly resumed items must not cause older local rich rows to be pushed into semantically wrong positions
- follow-up refreshes must converge without reordering already-stable transcript structure unnecessarily

## Follow-up Refresh Rules
Follow-up refresh exists to handle eventual consistency gaps after initial hydrate.

Required behavior:
- resume-based hydration should be followed by at least one refresh attempt
- more than one refresh may be required when the local transcript is richer or when a turn was recently streaming
- refresh should stop once the transcript is stable enough or the thread is no longer active
- refresh must continue to preserve local richness while incorporating newly available remote items

## Renderer Contract
This logic does not own rendering, but it must preserve renderer-significant transcript structure.

Hydration and merge must preserve:
- assistant message segments
- thought and reasoning segments
- plan segments
- tool-call and file-change detail
- streaming state
- row order that changes visible transcript meaning

If reconciliation collapses this structure into flat text, transcript correctness regresses even when the plain text still exists.

## Worked Examples

### Resume drops tool calls, local rich row must survive
Initial local state:
- user asks to repeat a task
- assistant row already contains summary text plus tool-call rows

Resumed state:
- contains the user message
- contains only the assistant summary text
- omits tool-call detail

Expected result:
- keep the local rich assistant row
- do not replace it with the shorter resumed row
- continue appending new deltas to the preserved assistant progression

Reference fixture:
- `AgmenteTests/Fixtures/CodexThreadReadMerge/thread_read_then_updates.json`

### Resume returns only an earlier assistant prefix
Initial local state:
- assistant row already includes start, midpoint, tool calls, and final completion text

Resumed state:
- only contains the opening assistant text for the same turn

Expected result:
- treat resumed content as an earlier, poorer snapshot
- preserve the richer local assistant row
- accept later deltas or refresh output without duplicating the already-preserved content

Reference fixture:
- `AgmenteTests/Fixtures/CodexThreadReadMerge/thread_read_same_prefix_then_updates.json`

### Resume adds new remote detail for an in-flight turn
Initial local state:
- current turn is streaming locally with partial assistant text

Resumed state:
- contains the same user turn
- contains the same assistant prefix
- adds a command execution item
- adds a later assistant message not yet present locally

Expected result:
- keep local streaming progression
- merge in the newly available command execution and later assistant message
- preserve transcript ordering

Reference fixture:
- `AgmenteTests/Fixtures/CodexThreadReadMerge/thread_read_overlaps_inflight_streaming.json`

### Resume thought items overlap a rich local tool row
Initial local state:
- assistant row already contains thoughts, messages, and tool calls in one rich progression

Resumed state:
- returns separate reasoning items and assistant messages that overlap that local row
- also returns genuinely new later reasoning and final answer content

Expected result:
- suppress overlapping resumed thought and assistant items already represented by the local rich row
- insert only the genuinely new later reasoning and final answer

Reference fixtures:
- `AgmenteTests/Fixtures/CodexThreadReadMerge/thread_read_partial_thought_dedup.json`
- `AgmenteTests/Fixtures/CodexThreadReadMerge/thread_read_combined_reasoning_dedup.json`

### Resume completes a backgrounded turn without duplicating earlier assistant text
Initial local state:
- user asks to refactor a module
- assistant already emitted the opening response before backgrounding

Resumed state:
- includes the same opening assistant message
- adds the command execution and final completion message

Expected result:
- keep only one copy of the opening assistant message
- ingest the newly available command and final assistant content

Reference fixture:
- `AgmenteTests/Fixtures/CodexThreadReadMerge/thread_read_after_background_turn_completion.json`

## Test Mapping
Changes to this behavior should be validated against:
- `AgmenteTests/CodexThreadReadMergeFixtureTests.swift`
- fixture coverage under `AgmenteTests/Fixtures/CodexThreadReadMerge/`

At minimum, changes should preserve behavior for:
- stale in-flight resume handling
- missing tool-call detail on resume
- reasoning and thought deduplication
- user-before-assistant ordering
- non-destructive follow-up refresh convergence

## Change Policy
When changing Codex load, resume, or merge behavior:
- update this spec in the same PR
- update or add fixture coverage for the changed scenario
- do not treat plain-text equivalence as sufficient if rich transcript structure would be lost
