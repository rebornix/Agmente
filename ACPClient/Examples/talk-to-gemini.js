#!/usr/bin/env node
// Minimal ACP stdio test against `npx @google/gemini-cli --experimental-acp`
// Usage: node talk-to-gemini.js
import { spawn } from "node:child_process";
import readline from "node:readline";

const child = spawn("npx", ["@google/gemini-cli@0.17.1", "--experimental-acp"], {
  stdio: ["pipe", "pipe", "pipe"],
});

let sessionId = null;
let initSent = false;
let newSessionSent = false;

child.on("exit", (code, signal) => {
  console.log(`[Agent] exited code=${code} signal=${signal ?? "none"}`);
});

const rl = readline.createInterface({ input: child.stdout });
rl.on("line", (line) => {
  if (!line.trim()) return;
  console.log("[Agent]", line);
  try {
    const msg = JSON.parse(line);
    handleMessage(msg);
  } catch (err) {
    console.warn("[Parser] failed to parse agent line", err);
  }
});

function send(obj) {
  const line = JSON.stringify(obj);
  console.log("[Client]", line);
  child.stdin.write(line + "\n");
}

function handleMessage(msg) {
  if (msg.id === "init-1") {
    console.log("[Info] initialize response received");
    console.log(JSON.stringify(msg.result, null, 2));
    if (!newSessionSent) {
      newSessionSent = true;
      send({
        jsonrpc: "2.0",
        id: "sess-1",
        method: "session/new",
        params: {
          cwd: process.cwd(),
          mcpServers: [], // This agent expects an array (even if empty)
        },
      });
    }
  }

  if (msg.id === "sess-1" && msg.result && msg.result.sessionId) {
    sessionId = msg.result.sessionId;
    console.log(`[Info] sessionId=${sessionId}`);
    sendPrompt();
  }
}

function sendPrompt() {
  if (!sessionId) {
    console.warn("[Warn] cannot send prompt: no sessionId yet");
    return;
  }
  send({
    jsonrpc: "2.0",
    id: "prompt-1",
    method: "session/prompt",
    params: {
      sessionId,
      prompt: [
        { type: "text", text: "Say hello from ACP over stdio" }
      ],
    },
  });
}

// Kick off initialize
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
    clientInfo: { name: "Node tester", title: "Node tester", version: "0.0.1" },
  },
});
initSent = true;

// Safety timeout to avoid hanging
setTimeout(() => {
  console.warn("[Warn] timeout waiting for responses; exiting");
  child.kill();
}, 20000);
