---
id: qwen-acp
protocol: acp
transport: stdio-to-ws
endpoint: ws://127.0.0.1:8765
start: npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "qwen --experimental-acp" --port 8765
stop: pkill -9 -f "stdio-to-ws.*8765"
cwd_required: true
supports: [session-list, session-load]
notes: Supports server-side session discovery and load flows.
---

# Qwen ACP Backend

- Prefer this backend for server-backed ACP recovery scenarios.
- Verify cwd exists before session creation.
