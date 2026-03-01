# Common Assertions

Reuse these phrases in scenarios when they match exactly.

## Session And Thread State
- `session remains selected`
- `thread remains selected`
- `user message remains visible`
- `assistant response streams in the same transcript`
- `no destructive reload occurs after initial creation`

## ACP Wire Expectations
- `initialize succeeds`
- `session/list fanout includes all known cwd values`
- `session/new succeeds`
- `session/prompt succeeds`
- `no immediate session/load follows a successful fresh session/new`

## Codex Wire Expectations
- `initialize succeeds`
- `thread/list succeeds`
- `thread/start or thread/resume succeeds`
- `turn/start succeeds`
- `active turn completion is reflected in the transcript`

## Cleanup
- `backend process is stopped`
- `simulator app state is removed`
