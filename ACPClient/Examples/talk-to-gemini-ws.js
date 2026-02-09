#!/usr/bin/env node
// Simple WS client to probe a stdio→WebSocket bridge (recommended: @rebornix/stdio-to-ws)
// for `npx @google/gemini-cli@0.17.1 --experimental-acp`.
// Usage: node talk-to-gemini-ws.js [ws://host:port/message]

const endpoint = process.argv[2] || "ws://127.0.0.1:8765/message";

async function main() {
  const ws = await makeWebSocket(endpoint);
  if (!ws) {
    console.error("Failed to create WebSocket. Ensure 'ws' is installed: npm i ws");
    process.exit(1);
  }

  ws.on("open", () => {
    send({
      jsonrpc: "2.0",
      id: "init-1",
      method: "initialize",
      params: {
        protocolVersion: 1,
        clientCapabilities: {
          fs: { readTextFile: true, writeTextFile: true },
          terminal: true,
        },
        clientInfo: { name: "WS tester", title: "WS tester", version: "0.0.1" },
      },
    });
  });

  ws.on("message", (data) => {
    const text = data.toString();
    for (const line of text.split("\n").filter((l) => l.trim())) {
      console.log("[Agent]", line);
      try {
        const msg = JSON.parse(line);
        handle(msg);
      } catch (err) {
        console.warn("[Parser] failed", err);
      }
    }
  });

  ws.on("close", (code, reason) => {
    console.log(`[WS] closed code=${code} reason=${reason}`);
    process.exit(0);
  });

  ws.on("error", (err) => {
    console.error("[WS error]", err);
  });

  function send(obj) {
    const line = JSON.stringify(obj);
    console.log("[Client]", line);
    ws.send(line + "\n"); // newline so stdio bridge parses it
  }

  function handle(msg) {
    if (msg.id === "init-1") {
      console.log("[Info] initialize response received");
      send({
        jsonrpc: "2.0",
        id: "sess-1",
        method: "session/new",
        params: { cwd: process.cwd(), mcpServers: [] },
      });
    }
    if (msg.id === "sess-1" && msg.result?.sessionId) {
      const sessionId = msg.result.sessionId;
      console.log(`[Info] sessionId=${sessionId}`);
      send({
        jsonrpc: "2.0",
        id: "prompt-1",
        method: "session/prompt",
        params: {
          sessionId,
          prompt: [
            { type: "text", text: "Say hello from ACP over WebSocket bridge" },
          ],
        },
      });
    }
  }
}

async function makeWebSocket(url) {
  try {
    let WebSocketCtor;
    try {
      const wsMod = await import("ws");
      WebSocketCtor = wsMod.WebSocket || wsMod.default;
    } catch (err) {
      console.error("Missing 'ws' package. Install with: npm i ws");
      return null;
    }
    return new WebSocketCtor(url);
  } catch (err) {
    console.error("Failed to create WebSocket", err);
    return null;
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
