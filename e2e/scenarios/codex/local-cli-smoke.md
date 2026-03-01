---
name: codex-local-cli-smoke
protocol: codex
backend: codex-local
target: ios-simulator
tags: [codex, simulator, smoke]
---

# Setup

- Start a local Codex app-server from `e2e/backends/codex-local.md`, or provide an already running compatible endpoint.
- Build and launch Agmente on the target simulator.

# Steps

1. Add a Codex server that points to the configured endpoint.
2. Connect and initialize the server.
3. Create or resume a thread.
4. Send a prompt.
5. Observe the assistant turn stream to completion.

# Assertions

- `thread remains selected`
- `user message remains visible`
- `assistant response streams in the same transcript`
- `initialize succeeds`
- `thread/list succeeds`
- `thread/start or thread/resume succeeds`
- `turn/start succeeds`
- `active turn completion is reflected in the transcript`

# Cleanup

- Stop the Codex backend if this run started it.
- Uninstall Agmente from the simulator.
