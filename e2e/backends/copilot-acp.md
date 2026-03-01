---
id: copilot-acp
protocol: acp
transport: stdio-to-ws
endpoint: ws://127.0.0.1:8765
start: npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "copilot --acp" --port 8765
stop: pkill -9 -f "stdio-to-ws.*8765"
cwd_required: true
supports: [session-list]
notes: Requires GitHub Copilot CLI 0.0.420 or newer for --acp support.
---

# Copilot ACP Backend

- Validate `copilot --version` before use.
- Keep `xcodebuildmcp` workspace config current when Copilot should expose simulator tools.
- Use a real host path for custom cwd runs.
