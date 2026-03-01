---
id: codex-local
protocol: codex
transport: websocket
endpoint: ws://127.0.0.1:8788
start: codex app-server --listen ws://127.0.0.1:8788
stop: pkill -9 -f "codex.*app-server.*8788"
cwd_required: false
supports: [thread-list, thread-resume, turn-start]
notes: Direct local Codex app-server over WebSocket.
---

# Codex Local Backend

- Use the direct websocket app-server for local Codex smoke and resume scenarios.
- If running from source, use the command documented in `Agents.md`.
