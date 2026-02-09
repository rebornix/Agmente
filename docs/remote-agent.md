# Start a Remote Agent

This is a short guide to run an agent on a remote host and connect it to Agmente.

## Quick Checklist
- Your agent exposes a WebSocket endpoint (ACP or Codex app-server).
- Use TLS (`wss://`) for public endpoints.
- Optional auth: bearer token and Cloudflare Access service token.
- Ensure WebSocket upgrades are allowed by your proxy.

## Run the Agent (ACP)
Most CLI agents speak ACP over stdio. Use `@rebornix/stdio-to-ws` to bridge to WebSocket:

```bash
npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "npx @google/gemini-cli --experimental-acp" --port 8765
```

Stop it:
```bash
pkill -9 -f "stdio-to-ws.*8765"
```

## Run the Agent (Codex app-server)
```bash
npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "codex app-server" --port 9000
```

## Expose the Endpoint
- Put a reverse proxy or Cloudflare Tunnel in front of the agent.
- Use `wss://` for remote access.

## Add the Server in Agmente
1. Open **Add Server**.
2. Pick the server type (ACP or Codex app-server).
3. Set **Protocol** to `wss`.
4. Enter the **Host** portion of your URL.
5. Add a **Bearer token** if required.
6. If using Cloudflare Access, enter **Client ID** and **Client Secret**.
7. Connect, then create a session.

For a longer walkthrough (tunnels, Access, and troubleshooting), see `setup.md`.
