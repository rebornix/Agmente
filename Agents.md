# Agmente Agents Guide

## Documentation Topology
- `Agents.md` (this file) is the root index for all coding agents.
- `CLAUDE.md` is the Cloud/Claude agent entrypoint and should reference the same component docs.
- Component-specific guidance lives next to code in nested files:
  - `Agmente/AGENTS.md`
  - `ACPClient/AGENTS.md`
  - `AppServerClient/AGENTS.md`
  - `AgmenteTests/AGENTS.md`
  - `AgmenteUITests/AGENTS.md`
  - `e2e/AGENTS.md`
- Root files should stay concise and link to nested docs instead of duplicating implementation detail.

## Documentation Update Policy
- Update `Agents.md` and `CLAUDE.md` in the same PR when adding:
  - a new top-level component/folder,
  - a new protocol integration (or protocol mode switch logic),
  - major architecture changes that affect more than one component.
- Update the closest nested `AGENTS.md` in the same PR when changing:
  - RPC method mappings,
  - protocol parsing/serialization behavior,
  - persistence/session/thread lifecycle behavior,
  - test contracts or required test env variables.
- If a code change does not require doc updates, note `Docs: N/A` in the PR description.

## Adding New Components or Protocols
- Create `<component>/AGENTS.md` when introducing a new component that has runtime logic or tests.
- Add the new component doc to both root files (`Agents.md` and `CLAUDE.md`).
- Document:
  - ownership boundaries,
  - key files and extension points,
  - required tests,
  - compatibility constraints with ACP/Codex and any migration behavior.

## Local External Repo Config
- Create `.agmente.paths` from `.agmente.paths.example` only if it does not already exist; otherwise keep your existing file and update keys as needed.
- `.agmente.paths` is local-only and gitignored.
- Use `.agmente.paths` as the single local path registry for ACP/Codex upstream checkouts.
- Required variables:
  - `AGMENTE_ACP_REPO`: local `agent-client-protocol` checkout.
  - `AGMENTE_CODEX_REPO`: local `codex` checkout (must contain `codex-rs`).

## What this app does
- Connect to an Agent Client Protocol (ACP) server over WebSocket.
- Connect to an OpenAI Codex app-server over WebSocket.
- Detect protocol after `initialize` and route requests to the matching client/runtime.
- Keep ACP session flow and Codex thread/turn flow separate in app state and UI.

## Protocol modes in Agmente
- **ACP mode** uses ACP RPC methods (`session/new`, `session/prompt`, `session/cancel`, optional `session/list` and `session/load`).
- **Codex mode** uses app-server v2 methods (`thread/start`, `thread/resume`, `thread/list`, `turn/start`, `turn/interrupt`, `model/list`, `skills/list`).
- **Detection**: if `initialize` returns a Codex `userAgent` (for example `codex/…`), Agmente switches to Codex mode for that server.

## Adding your own agent
- Tap **Add Server**, then choose **ACP** or **Codex** in `ServerTypePicker`.
- Enter your WebSocket endpoint and optional bearer token.
- Set the working directory if your agent expects one.
- Save, then **Connect** and **Initialize** (if not done automatically).
- Create a new session to begin chatting.

## Sessions
- Sessions/threads are kept in memory per server during the app lifecycle.
- **ACP sessions**
  - For servers without `session/list` support (like Gemini), sessions are persisted to local storage (Core Data) so they remain visible after app restart.
  - If `session/load` is available, opening a persisted session restores full conversation history from the server.
  - If `session/list` is available, the app refreshes server-side session summaries.
- **Codex threads**
  - The app uses `thread/list` for summaries and `thread/resume` for full history.
  - `cwd`/timestamp metadata comes from `thread/list` when provided; if missing on older servers, cached values are preserved.
  - New prompts are sent with `turn/start`, and streaming updates are rendered from turn/item notifications.
- **Persistence with `@rebornix/stdio-to-ws`**: when using `--persist`, the server keeps the child process alive during disconnections and buffers messages. Agmente sends a persistent `X-Client-Id` header on every connection so reconnecting clients can replay buffered messages.
- Each session/thread opens a chat transcript view; tool calls are surfaced as system messages.

## Running Local Agents

### Codex app-server (direct WebSocket)

```bash
# If codex is installed in PATH
codex app-server --listen ws://127.0.0.1:8788

# Or from Codex source checkout (read `AGMENTE_CODEX_REPO` from `.agmente.paths`)
cd <AGMENTE_CODEX_REPO>/codex-rs
cargo run -p codex-cli -- app-server --listen ws://127.0.0.1:8788
```

Stop Codex app-server:
```bash
pkill -9 -f "codex.*app-server.*8788"
```

Add a server with:
- `Server Type`: `Codex`
- Endpoint: `ws://127.0.0.1:8788`

> Note: per Codex upstream docs, WebSocket transport is currently marked experimental.

### Standard Commands (for VS Code auto-approve)

> **Important:** Always run stop and start as **separate commands** (never chained with `&&` or `;`). This ensures consistent command strings for VS Code auto-approve.

**Start agent server:**
```bash
npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "npx @google/gemini-cli --experimental-acp" --port 8765
```

**Stop agent server:**
```bash
pkill -9 -f "stdio-to-ws.*8765"
```

### Alternative Agents
```bash
# Vibe agent (Mistral)
npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "vibe-acp" --port 8765

# Claude Code
npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "npx @zed-industries/claude-code-acp" --port 8765

# Qwen agent (supports session/list)
npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "qwen --experimental-acp" --port 8765
```

Add a server with endpoint: `ws://localhost:8765`

> Tip: Always use `--persist` flag with `stdio-to-ws`. This keeps the child process alive during brief disconnections (e.g., iOS app backgrounding) and buffers messages for replay on reconnect. Agmente automatically sends a persistent `X-Client-Id` header to enable this feature. Use `--grace-period` to keep the process alive for a set time (seconds) after disconnect.

---

## Running Tests

### ACPClient (SwiftPM)
```bash
swift test --package-path /path/to/Agmente-oss/ACPClient
```

### App Tests (Xcode)
List destinations and pick a simulator UDID:
```bash
xcodebuild -project /path/to/Agmente-oss/Agmente.xcodeproj -scheme Agmente -showdestinations
```

Run tests:
```bash
xcodebuild -project /path/to/Agmente-oss/Agmente.xcodeproj \
  -scheme Agmente \
  -destination "platform=iOS Simulator,id=<SIMULATOR_UDID>" \
  test
```

---

## E2E Scenarios

- Repository-owned E2E specs live under `e2e/`.
- Start with `e2e/README.md`, then read:
  - `e2e/AGENTS.md`
  - `e2e/schema/scenario-frontmatter.md`
  - `e2e/backends/`
- `e2e/scenarios/`
- Scenarios define what to test.
- Skills in `.agents/skills/` are optional execution helpers and must not be the source of truth for scenario behavior.
- When a user asks to run an E2E scenario, resolve the request from `e2e/scenarios/` first.
- `run`, `execute`, `validate`, and `reproduce` scenario requests mean execute-only, no repository edits.
- Agentic testing means the agent should actually launch the backend, drive the simulator or protocol tools, capture evidence, evaluate assertions, and clean up.
- If an execute-only run is blocked by missing hooks or incomplete automation affordances, report the blocker and stop.
- Only edit code, tests, skills, or docs when the user explicitly asks to fix, stabilize, or make the scenario executable.

## Simulator Automation Guardrails

### Prerequisites
- Xcode installed with iOS Simulator
- Xcode Build MCP server running (provides `mcp_xcodebuildmcp_*` tools)

### Testing Workflow

1. **Start the local agent** - Run one of the agent commands above in a terminal
2. **Build & run** - Discover project, list simulators, build and run on simulator
3. **Verify UI** - Use `describe_ui` + `screenshot` to check UI state
4. **Interact** - Tap, type, gesture to test features (always use `describe_ui` for coordinates)
5. **Validate** - Screenshot + describe_ui to confirm results
6. **Iterate** - Stop app, rebuild if code changes needed
7. **🧹 Cleanup (REQUIRED)** - Kill the agent server and uninstall the app from simulator

> ⚠️ **IMPORTANT: Always complete the cleanup step!** Failing to stop the agent server leaves a process running on port 8765, and failing to uninstall the app leaves stale state in the simulator.

### UI Automation Guardrails (Required)

Use these rules for every simulator automation run to avoid wrong taps and wrong mode selection:

1. **Never tap from screenshots alone.** Always run `describe_ui` immediately before any tap/long-press/swipe that depends on coordinates.
2. **Prefer semantic targeting first.** Use `tap(id: ...)` or `tap(label: ...)` before raw `x,y` coordinates.
3. **Treat coordinates as single-use.** After any navigation, modal, keyboard show/hide, or form validation state change, run `describe_ui` again before the next coordinate tap.
4. **Verify segmented control state explicitly.** For `ServerTypePicker` and `ProtocolPicker`, do not assume selection from a prior run; verify selected mode from nearby text or resulting UI state after tapping.
5. **Use post-action assertions.** After critical actions (for example ACP vs Codex selection), confirm expected text is visible:
   - ACP mode should show ACP guidance text.
   - Codex mode should show `OpenAI Codex app-server protocol`.
6. **Do not continue after ambiguous state.** If UI elements overlap (e.g. warning sheet over form) or expected controls are duplicated, stop and re-read hierarchy before proceeding.
7. **Record key checkpoints in logs.** For E2E runs, capture and verify event progression (initialize, thread start/resume, turn start, turn completed) before declaring success.

### Generic Coverage Checklist

Scenario-specific behavior now belongs under `e2e/scenarios/`. The checklist below is only a broad regression sweep.

#### ✅ Server Connection Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| Add ACP server | Add Server → select ACP → Enter `ws://localhost:8765/message` → Save | Server saved, can connect |
| Add Codex server | Add Server → select Codex → Enter `ws://127.0.0.1:8788` → Save | Server saved, can connect |
| Connect to server | Tap Connect on server | Status shows "Connected" |
| Initialize client | Connect → Initialize | Status shows "Initialized" |
| Handle connection error | Enter invalid endpoint | Error message displayed |

#### ✅ Session Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| Create new session | Tap "+" or "New Session" | New session appears in sidebar |
| Select session | Tap on session | Chat view opens |
| Send message | Type message → Send | Message appears, response received |
| Cancel request | Send message → Tap cancel | Request cancelled, UI responsive |

#### ✅ UI/UX Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| Keyboard dismiss | Tap outside text field | Keyboard dismisses |
| Scroll chat | Swipe up/down in chat | Smooth scrolling |
| Tool calls display | Send message triggering tools | Tool calls shown as system messages |

### Important Testing Notes

- **Start/stop the agent**: Always start a local agent before testing, and kill it when done.
- **Use `describe_ui` for coordinates**: Don't guess tap coordinates from screenshots.
- **Wait for responses**: Agent processing takes time; use `postDelay`/`preDelay` parameters on tap commands instead of running separate `sleep` commands (which can kill the agent server).
- **Rebuild after changes**: Stop the app, then rebuild to ensure fresh code is deployed.
- **Never run `sleep` in the same terminal as the agent**: Running `sleep` or other commands in the agent server's terminal will kill the server. Always use a different terminal or use tap delay parameters.

### Known Issues & Workarounds

#### Add Server form defaults
The Add Server form should have no placeholder values for scheme or host - users must enter these explicitly. Defaults:
- **Protocol**: `ws` (most common for local testing)
- **Host**: empty
- **Working Directory**: empty

#### Working directory path
The working directory is sent when creating new sessions. If the path doesn't exist on the agent's host, session creation will fail with:
```
ENOENT: no such file or directory, realpath '/path/that/does/not/exist'
```
- **Fix**: Leave working directory empty, or set a valid path on the agent's host.
- For local testing on macOS, the default is `/path/to/your/workspace`.

#### Existing server with bad config
If you previously saved a server with incorrect settings (wrong scheme, bad working directory), you may need to delete and re-add it after fixing the defaults in code. To delete: tap the "..." menu → Delete.

#### Killing the agent server
After testing, **always** stop the local agent server:
```bash
pkill -9 -f "stdio-to-ws.*8765"
```

#### Uninstalling the app from simulator
**Always** remove the app from the simulator when done testing:
```bash
xcrun simctl uninstall <SIMULATOR_UUID> com.example.Agmente
```
You can get the simulator UUID from `xcrun simctl list devices` or from the `list_sims` tool.

---

## 🧹 End-of-Test Cleanup Checklist

**Both steps are required after every test session:**

| Step | Command | Why |
|------|---------|-----|
| 1. Stop agent server | `pkill -9 -f "stdio-to-ws.*8765"` | Frees port 8765 for future tests |
| 2. Uninstall app | `xcrun simctl uninstall <UUID> com.example.Agmente` | Removes stale app state |

> 💡 **Tip**: Run these as the final step of every test, even if the test failed partway through.

---

## ACPClient reference
- The iOS app uses the local `ACPClient` Swift package (`Agmente/ACPClient`) to speak ACP over WebSocket.
- ACP protocol/spec upstream reference checkout: `AGMENTE_ACP_REPO/docs` (especially `AGMENTE_ACP_REPO/docs/protocol` and `AGMENTE_ACP_REPO/docs/schema`).
- Key types: `ACPClientConfiguration` (endpoint, auth token provider, ping), `ACPClient` (connect/send), and delegate callbacks for state and messages.
- RPC entry points used in the app: `initialize`, `session/new`, `session/prompt`, `session/cancel`, and optional `session/list`.
- If you extend the client, keep new RPC methods consistent with ACP JSON-RPC envelopes and add handlers to `ACPViewModel`.

## Capabilities sent on initialize
- Filesystem read/write toggles (default on).
- Terminal support toggle (default on).
- Client info defaults: name `Agmente iOS`, version `0.1.0`.

---

## Codex app-server reference (local source)
- App-server implementation: `AGMENTE_CODEX_REPO/codex-rs/app-server`
  - README for protocol flow and examples: `AGMENTE_CODEX_REPO/codex-rs/app-server/README.md`
- Protocol types/schema: `AGMENTE_CODEX_REPO/codex-rs/app-server-protocol`
  - v2 protocol definitions (Thread/Turn/Item): `AGMENTE_CODEX_REPO/codex-rs/app-server-protocol/src/protocol/v2.rs`
- Schema generation (from installed Codex CLI):
  - `codex app-server generate-ts --out DIR`
  - `codex app-server generate-json-schema --out DIR`
