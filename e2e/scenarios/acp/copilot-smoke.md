---
name: copilot-acp-smoke
protocol: acp
backend: copilot-acp
target: ios-simulator
tags: [acp, copilot, simulator, smoke]
requires:
  - copilot >= 0.0.420
  - macOS Accessibility enabled when host-side Simulator input is required
  - port 8765 free
---

# Setup

- Build and launch Agmente on a clean simulator.
- Add an ACP server named `Copilot ACP E2E` that points to `localhost:8765`.
- Use a valid host working directory such as `/tmp`.
- Confirm the server initializes and shows a Copilot version card.

# Steps

1. Start the Copilot ACP backend from `e2e/backends/copilot-acp.md`.
2. Verify the Agmente empty state before creating a session.
3. Trigger session refresh and confirm sessions can be listed for known cwd values.
4. Create a fresh session.
5. Send `Reply with exactly: Hello from Copilot ACP E2E.`
6. Observe the first user message and assistant stream in the same transcript.
7. Optionally repeat the flow from a custom cwd different from the server default.

# Assertions

- `session remains selected`
- `user message remains visible`
- `assistant response streams in the same transcript`
- `initialize succeeds`
- `session/list fanout includes all known cwd values`
- `session/new succeeds`
- `session/prompt succeeds`
- `no immediate session/load follows a successful fresh session/new`

# Failure Insights

- Older Copilot builds can accept the bridge connection and still fail immediately because they do not support `--acp`.
- A stale or invalid working directory can make `session/new` fail with a host realpath error.
- The resolved ACP session id must replace the placeholder session without discarding in-memory transcript state.

# Checkpoints

- Empty state before adding a server
- Connected server card after initialization
- Fresh session with the prompt visible
- Completed assistant response

# Cleanup

- Stop the backend with the command from `e2e/backends/copilot-acp.md`.
- Uninstall Agmente from the simulator.
