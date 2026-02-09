# First time user

Agents to test:
- Gemini
  - No support for session/list or session/load
- Qwen
  - Supports session/list (not listed as capability) and session/load

## Server Management
- [ ] Add a new server with valid WebSocket endpoint with working directory configured
- [ ] Display agent capabilities after initialization (Image, Audio, Context badges)
- [ ] Show "Limited session recovery" warning for agents without `session/list`

## New Session

- [ ] Create a new session via "+" button
- [ ] Session opens automatically after creation
- [ ] Text field accepts input
- [ ] Send button is enabled when text is entered
- [ ] Send a text message to agent
- [ ] Message appears in chat transcript
- [ ] Receive response from agent
- [ ] Response renders correctly in chat view


## Session Management
- [ ] Navigate back to session list
- [ ] Create another session (send a different message)
- [ ] Switch between multiple sessions

## Session Persistence

- [ ] When using a server with `session/load`, restart app and verify sessions are fetched from server
  - [ ] Verify session can be opened after restart, and chat history is loaded from server
- [ ] When using a server without `session/list` or `session/load`, restart app and verify sessions persist
  - [ ] Sessions are loaded from local storage
  - [ ] Verify session can be opened after restart, and chat history is loaded from server

## RPC Verification

- [ ] `initialize` RPC sent on client initialization
- [ ] `session/list` RPC sent (when supported)
- [ ] `session/new` RPC sent on session creation
- [ ] `session/prompt` RPC sent on message send
- [ ] `session/cancel` RPC sent on request cancellation
