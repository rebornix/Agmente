---
name: acp-first-time-user
protocol: acp
backends: [gemini-acp, qwen-acp]
target: ios-simulator
tags: [acp, onboarding, persistence]
---

# Setup

- Choose one backend from the front matter.
- Add a new ACP server with a valid websocket endpoint.
- Configure a working directory when the chosen backend requires one.

# Steps

1. Initialize the server connection.
2. Create a new session from the `+` button.
3. Send a text message and wait for the response.
4. Navigate back and create another session with a different message.
5. Switch between the two sessions.
6. Restart the app and reopen the server.

# Assertions

- New sessions open automatically after creation.
- The text field accepts input and enables send only when text is present.
- The user message and assistant response render correctly.
- Gemini-backed runs preserve sessions through local storage fallback.
- Qwen-backed runs recover sessions through server-side list/load behavior.

# Cleanup

- Stop the chosen backend.
- Uninstall Agmente from the simulator.
