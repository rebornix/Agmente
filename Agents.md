# Agmente Agents Guide

## What this app does
- Connect to an Agent Client Protocol (ACP) server over WebSocket.
- Initialize the client, then create sessions to chat with the agent.
- Cache sessions in memory (many agents do not support `session/list`).

## Adding your own agent
- Tap **Add Server** and enter your WebSocket endpoint and optional bearer token.
- Set the working directory if your agent expects one.
- Save, then **Connect** and **Initialize** (if not done automatically).
- Create a new session to begin chatting.

## Sessions
- Sessions are kept in memory per server during the app lifecycle.
- **For servers without `session/list` support** (like Gemini), sessions are automatically persisted to local storage (Core Data). This allows you to see your session list after app restart.
- **Session recovery with `session/load`**: If the server supports `session/load`, the app will use it to restore the full conversation history when you open a persisted session.
- **Persistence with `@rebornix/stdio-to-ws`**: When using `@rebornix/stdio-to-ws --persist`, the server keeps the child process alive during disconnections and buffers messages. Agmente sends a persistent `X-Client-Id` header on every connection, allowing the server to recognize reconnecting clients and replay buffered messages. This is ideal for mobile apps where backgrounding causes brief disconnects.
- If your agent does expose `session/list`, the app will fetch sessions from the server.
- Each session opens a chat transcript view; tool calls are surfaced as system messages.

## Running a Local Agent

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

## Testing with Xcode Build MCP

The app can be tested in the iOS Simulator using the Xcode Build MCP tools. This section serves as a **testing specification** for verifying new changes and features.

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

### Testing Scenarios Checklist

#### ✅ Server Connection Tests
| Test | Steps | Expected Result |
|------|-------|-----------------|
| Add custom server | Add Server → Enter `ws://localhost:8765/message` → Save | Server saved, can connect |
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
- Key types: `ACPClientConfiguration` (endpoint, auth token provider, ping), `ACPClient` (connect/send), and delegate callbacks for state and messages.
- RPC entry points used in the app: `initialize`, `session/new`, `session/prompt`, `session/cancel`, and optional `session/list`.
- If you extend the client, keep new RPC methods consistent with ACP JSON-RPC envelopes and add handlers to `ACPViewModel`.

## Capabilities sent on initialize
- Filesystem read/write toggles (default on).
- Terminal support toggle (default on).
- Client info defaults: name `Agmente iOS`, version `0.1.0`.

---

## Codex app-server reference (local source)
- App-server implementation: `/path/to/codex/codex-rs/app-server`
  - README for protocol flow and examples: `/path/to/codex/codex-rs/app-server/README.md`
- Protocol types/schema: `/path/to/codex/codex-rs/app-server-protocol`
  - v2 protocol definitions (Thread/Turn/Item): `/path/to/codex/codex-rs/app-server-protocol/src/protocol/v2.rs`
