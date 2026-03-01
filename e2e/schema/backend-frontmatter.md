# Backend Front Matter

Use this front matter at the top of every `e2e/backends/*.md` file.

## Required Keys
- `id`: stable backend identifier
- `protocol`: `acp` or `codex`
- `transport`: `websocket`, `stdio-to-ws`, or another documented transport

## Optional Keys
- `endpoint`: websocket endpoint used by the app
- `start`: canonical start command
- `stop`: canonical stop command
- `cwd_required`: whether the backend requires a valid host working directory
- `supports`: capability tags such as `session-list`, `session-load`, `resume`
- `notes`: short one-line summary

## Example

```md
---
id: copilot-acp
protocol: acp
transport: stdio-to-ws
endpoint: ws://127.0.0.1:8765
start: npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "copilot --acp" --port 8765
stop: pkill -9 -f "stdio-to-ws.*8765"
cwd_required: true
supports: [session-list]
---
```
