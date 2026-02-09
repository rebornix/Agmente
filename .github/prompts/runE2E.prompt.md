---
name: runE2ETest
description: Run end-to-end tests for Agmente iOS app with a local ACP agent
argument-hint: "agent name and feature to test"
---

Run an end-to-end test for **Agmente** iOS app using Xcode Build MCP tools. Reference: Agents.md

## Workflow

1. **Setup Phase**
   - Start the ACP agent server (use `isBackground: true`):
     - **Gemini** (default): `npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "npx @google/gemini-cli --experimental-acp" --port 8765`
     - **Claude**: `npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "npx @zed-industries/claude-code-acp" --port 8765`
     - **Qwen**: `npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "qwen --experimental-acp" --port 8765`
     - **Vibe**: `npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "vibe-acp" --port 8765`
   - Build and run app with `build_run_sim`

2. **Testing Phase** (default: full sanity test)
   - Call `activate_ui_interaction_tools` to enable tap/swipe/type
   - **Add Server**: Tap "Add Server" → Fill form:
     - Name: any display name
     - Protocol: `ws`
     - Host: `localhost:8765`
     - Working directory: `/path/to/your/workspace` (must exist on host)
   - **Save & Connect**: Tap "Save Server" → Review agent capabilities → "Acknowledge and Add"
   - **Create Session**: Tap "New Session" button
   - **Send Message**: Tap text field → `type_text` → Tap Send button
   - **Verify Response**: Check `get_terminal_output` for `session/new` and `session/prompt` RPC calls
   - Use `describe_ui` before every tap to get accurate coordinates
   - Use `postDelay` parameter (max 10s) instead of `sleep` commands
   - Take `screenshot` after key actions

3. **Validation Phase**
   - Verify agent capabilities displayed (Image, Audio, Context badges)
   - Verify "Limited session recovery" warning for agents without `session/list`
   - Verify session appears in sidebar with correct count ("1 idle")
   - Check terminal output for expected RPC sequence: `initialize` → `session/list` → `session/new` → `session/prompt`

4. **Cleanup Phase (REQUIRED)**
   - Stop agent server: `pkill -9 -f "stdio-to-ws.*8765"`
   - Uninstall app: `xcrun simctl uninstall <SIMULATOR_UUID> com.example.Agmente`
   - **Always complete cleanup even if tests fail**

## Test Scenarios (from Agents.md)

| Category | Test | Steps | Expected |
|----------|------|-------|----------|
| Server | Add server | Add Server → ws://localhost:8765 → Save | Server saved |
| Server | Connect | Tap on server | Green indicator, capabilities shown |
| Session | Create | Tap "New Session" | Session in sidebar |
| Session | Send message | Type → Send | Message sent, response received |
| UI | Keyboard dismiss | Tap outside text field | Keyboard dismisses |

## Output Format

| Test | Status | Notes |
|------|--------|-------|
| Agent server started | ✅/❌ | |
| App built and launched | ✅/❌ | |
| Server added | ✅/❌ | |
| Session created | ✅/❌ | |
| Message sent | ✅/❌ | |
| Cleanup completed | ✅/❌ | |

## Important Notes

- **Never chain commands** with `&&` or `;` - run start/stop as separate commands
- **Never run `sleep`** in agent server terminal - it kills the server
- **Working directory must exist** or session creation fails with ENOENT
- Use `describe_ui` before tapping - don't guess from screenshots
- Tap by `id` or `label` when available
