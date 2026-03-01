---
id: gemini-acp
protocol: acp
transport: stdio-to-ws
endpoint: ws://127.0.0.1:8765
start: npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "npx @google/gemini-cli --experimental-acp" --port 8765
stop: pkill -9 -f "stdio-to-ws.*8765"
cwd_required: false
supports: []
notes: Does not provide session/list or session/load.
---

# Gemini ACP Backend

- Use this backend for persistence-fallback scenarios.
- Expect local storage fallback for session visibility after app relaunch.
