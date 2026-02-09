# Remote Agent Setup (Long Form)

This guide shows how to **start a remote agent** and connect it to Agmente over a secure WebSocket. It summarizes the internal website docs without pulling in the full site.

## 0) Choose Your Protocol

Agmente supports two server types:
- **ACP** (most common for CLI agents).
- **Codex app-server** (if your server already speaks the Codex protocol).

You will select the server type in the app later, but it matters for which agent command you run.

## 1) Prerequisites

Remote host requirements:
- A VPS or server you control.
- A stable DNS name (recommended).
- TLS termination (`wss://`) in front of the WebSocket.
- A firewall that allows inbound HTTPS (443).

Agent requirements:
- Node.js 18+ (for `stdio-to-ws` and many agent CLIs).
- The agent CLI installed and authenticated on the server.

## 1.5) What the Flow Looks Like (At a High Level)

- Agmente connects over `wss://` to your public hostname.
- A proxy or tunnel forwards traffic to `localhost:<port>` on the server.
- The agent process speaks ACP or Codex app-server over WebSocket.

## 2) Authenticate the Agent CLI (Once)

Agmente never handles OAuth or API keys. Authenticate the agent CLI on the remote host before you launch it.

Examples:
- **Claude Code**
  ```bash
  npx -y @anthropic-ai/claude-code /login
  ```
- **Gemini CLI**: sign in with OAuth or set `GEMINI_API_KEY`.
- **Qwen**: OAuth login or API key.
- **Vibe (Mistral)**: OAuth login or `MISTRAL_API_KEY`.

## 3) Start the Agent (ACP)

Most agents speak ACP over stdio. Bridge them to WebSocket with `@rebornix/stdio-to-ws`.

**Recommended flags**
- `--persist`: keeps the child process alive across reconnects so session IDs stay valid.
- `--grace-period 604800`: allows a 7‑day reconnect window.

**Why `--persist` matters**
If an agent does not implement `session/list` or `session/load`, Agmente stores session IDs locally. Keeping the agent process alive across reconnects preserves those sessions.

### Gemini CLI
```bash
npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "npx @google/gemini-cli --experimental-acp" --port 8765
```

### Claude Code
```bash
npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "npx @zed-industries/claude-code-acp" --port 8765
```

### Qwen
```bash
npm install -g qwen-cli
npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "qwen --experimental-acp" --port 8765
```

### Vibe (Mistral)
```bash
npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "vibe-acp" --port 8765
```

### Stop the bridge
```bash
pkill -9 -f "stdio-to-ws.*8765"
```

## 4) Start the Agent (Codex app-server)

If your server speaks the Codex app-server protocol, run it directly and expose a WebSocket endpoint.

Example (local-style command on the server):
```bash
npx -y @rebornix/stdio-to-ws --persist --grace-period 604800 "codex app-server" --port 9000
```

You’ll select **Server Type = Codex App-Server** in Agmente and use port `9000` (or your chosen port).

## 5) Put TLS in Front of the WebSocket

Remote agents should be accessed over `wss://`.

### Option A: Reverse Proxy (Caddy)

`Caddyfile` example:
```text
agent.example.com {
  reverse_proxy localhost:8765
}
```

### Option B: Cloudflare Tunnel

**Install `cloudflared`**
- macOS: `brew install cloudflared`
- Windows: download from Cloudflare’s releases page
- Linux (Debian/Ubuntu):
  ```bash
  a=$(mktemp) \
  && curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg \
  && echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list \
  && sudo apt update \
  && sudo apt install cloudflared
  ```

**Quick tunnel (temporary URL):**
```bash
cloudflared tunnel --url http://localhost:8765
```

Quick tunnels generate a new URL each run. Use a named tunnel for a stable hostname.

**Named tunnel (stable URL):**
```bash
cloudflared tunnel login
cloudflared tunnel create agmente-agent
cloudflared tunnel route dns agmente-agent agent.example.com
```

`~/.cloudflared/config.yml`:
```yaml
tunnel: <YOUR_TUNNEL_ID>
credentials-file: /Users/yourname/.cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: agent.example.com
    service: http://localhost:8765
  - service: http_status:404
```

Run the tunnel:
```bash
cloudflared tunnel run agmente-agent
```

**Run as a service**
- macOS:
  ```bash
  cloudflared service install
  sudo launchctl start com.cloudflare.cloudflared
  ```
- Linux:
  ```bash
  sudo cloudflared service install
  sudo systemctl enable --now cloudflared
  ```
- Windows:
  ```powershell
  cloudflared service install
  net start cloudflared
  ```

## 6) (Optional) Add Cloudflare Access

Cloudflare Access adds authentication in front of your tunnel. Agmente supports **Service Tokens**.

### Create Access + Service Token
1. Access → Applications → **Add** → **Self-hosted**
2. Name it (for example `Agmente Agent`) and set your tunnel domain.
3. Access → Service Auth → **Service Tokens** → Create a token.
4. Add a policy using **Service Auth** and include the token.

### Configure Agmente
Enter the token values under **Cloudflare Access**:
- `CF-Access-Client-Id`
- `CF-Access-Client-Secret`

Agmente sends these on every request:
```
CF-Access-Client-Id: <CLIENT_ID>
CF-Access-Client-Secret: <CLIENT_SECRET>
```

### Test Access
```bash
curl -I https://agent.example.com \
  -H "CF-Access-Client-Id: YOUR_CLIENT_ID" \
  -H "CF-Access-Client-Secret: YOUR_CLIENT_SECRET"
```

## 7) Add the Remote Server in Agmente

1. Tap **Add Server**.
2. Pick **ACP** or **Codex App-Server**.
3. Set **Protocol** to `wss`.
4. Enter the **Host** (e.g. `agent.example.com` or `agent.example.com/message`).
5. Add a **Bearer token** if your agent requires it.
6. Add **Cloudflare Access** credentials if enabled.
7. Set **Working directory** only if your agent expects one and the path exists on the server.
8. Save, connect, then create a session.

**Host formatting tip**
Some relays expose `/message` (for example `agent.example.com/message`). Use the exact host/path your server expects.

## 8) Verify the Connection

**Basic checks**
- `curl -I https://agent.example.com` should respond (200 or 403 if Access missing).
- The WebSocket endpoint must accept upgrade requests.

**Codex app-server health**
You should see:
1. `initialize`
2. `thread/list`
3. `thread/start` (or `thread/resume`)
4. `turn/start`
5. `turn/completed`

If these complete, the server is healthy.

## 9) Troubleshooting

**Connection refused**
- Verify the agent process is running and listening on the correct port.
- Confirm firewall rules and reverse proxy config.

**WebSocket connects then drops**
- Use `--persist` so the child process survives reconnects.
- Run the bridge/tunnel as a service for stability.

**403 Forbidden (Cloudflare Access)**
- Ensure the Access policy uses **Service Auth**.
- Confirm the token is attached to the policy.
- Re-enter the Client ID/Secret in Agmente and reconnect.

**Working directory errors**
- The directory must exist on the agent host.
- Avoid `/` as a working directory.

## 10) Security Notes

- Always use `wss://` for remote endpoints.
- Use Cloudflare Access or a bearer token for any public endpoint.
- Rotate service tokens periodically.
- Use unique hostnames and keep logs for audit.

---

If you only need local access, see `Agents.md` for LAN setup instructions.
