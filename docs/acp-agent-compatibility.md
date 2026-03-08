# ACP Agent Compatibility Matrix

This file tracks the current ACP support surface of external CLI agents that are relevant to Agmente.

Method:
- Repos were cloned locally under `/Users/lvpeng/Code/agent-repos`.
- Support was classified from ACP implementation files where available.
- If no implementation files were present in the public repo, support was classified from current docs/changelog only.

Date checked: 2026-02-28

## Summary Matrix

| Repo | HEAD | ACP status | Core RPCs | Update events | Notes |
| --- | --- | --- | --- | --- | --- |
| `kimi-cli` | `e2193d9` | Native ACP, code-backed | `initialize`, `session/new`, `session/load`, `session/list`, `session/prompt`, `session/cancel`, `session/set_mode`, `session/set_model` | `available_commands_update`, `session/update` flow | No `resume`/`fork`; no `configOptions`; only default mode |
| `mistral-vibe` | `5d2e01a` | Native ACP, code-backed | `initialize`, `authenticate` stub, `session/new`, `session/load`, `session/list`, `session/prompt`, `session/cancel`, `session/set_mode`, `session/set_model`, `session/set_config_option` | rich streaming: message chunks, thought chunks, tool updates, plan, available commands | Strong generalized ACP surface |
| `opencode` | `2a2082233` | Native ACP, code-backed | `initialize`, `authenticate` stub, `session/new`, `session/load`, `session/list`, `session/fork`, `session/resume`, `session/prompt`, `session/cancel`, `session/set_mode`, `session/set_model` | message chunks, thought chunks, tool updates, plan, usage | Code is ahead of its ACP README |
| `claude-code-acp` | `1b05792` | Native ACP bridge, code-backed | `initialize`, `authenticate` stub, `session/new`, `session/load`, `session/list`, `session/fork`, `session/resume`, `session/prompt`, `session/cancel`, `session/set_mode`, `session/set_model`, `session/set_config_option` | very rich streaming incl. `config_option_update`, `current_mode_update`, tool updates, plan, usage | Best reference implementation in this set |
| `auggie` | `87156b2` | Native ACP claimed, docs/changelog-backed | Docs mention `--acp`, terminal auth, model selection, indexing control | Docs mention image/file mention support | ACP server implementation not found in current public repo contents |
| `factory` | `3d9840a` | ACP supported via CLI docs, docs-backed | Docs show `droid exec --output-format acp` for Zed/JetBrains | Changelog mentions ACP daemon/session loading fixes | ACP implementation source not found in current public repo contents |
| `junie` | `ace62f2` | No confirmed ACP path found | None found in repo scan | None found | Treat as not currently confirmed ACP-capable for Agmente |

## Repo Notes

### kimi-cli

Primary files:
- `/Users/lvpeng/Code/agent-repos/kimi-cli/src/kimi_cli/acp/server.py`
- `/Users/lvpeng/Code/agent-repos/kimi-cli/src/kimi_cli/acp/AGENTS.md`

Observed support:
- `initialize` advertises `load_session`, `session/list`, image prompts, HTTP MCP, and terminal-auth metadata.
- `new_session` returns `modes` and `models`.
- `load_session`, `list_sessions`, `prompt`, `cancel`, `set_session_mode`, `set_session_model` are implemented.
- Tool approval is wired through ACP permission requests in session logic.

Gaps:
- No `session/resume` or `session/fork`.
- No `session/set_config_option`.
- Mode support is effectively fixed to `default`.

### mistral-vibe

Primary files:
- `/Users/lvpeng/Code/agent-repos/mistral-vibe/vibe/acp/acp_agent_loop.py`
- `/Users/lvpeng/Code/agent-repos/mistral-vibe/docs/acp-setup.md`

Observed support:
- `initialize`, `new_session`, `load_session`, `list_sessions`, `prompt`, `cancel`, `set_session_mode`, `set_session_model`, `set_config_option`.
- `new_session` and `load_session` return both legacy `modes` and generalized `config_options`.
- ACP permissions are implemented via `request_permission`.
- Client FS and terminal capabilities are used to install ACP-specific tool overrides.
- Streams replay/history and live updates including agent/user chunks, thought chunks, tool updates, plan entries, and available commands.

Gaps:
- `authenticate` is stubbed.
- `resume_session` and `fork_session` are explicitly not implemented.

### opencode

Primary files:
- `/Users/lvpeng/Code/agent-repos/opencode/packages/opencode/src/acp/agent.ts`
- `/Users/lvpeng/Code/agent-repos/opencode/packages/opencode/src/acp/README.md`

Observed support from code:
- `initialize` advertises `loadSession`, `fork`, `list`, `resume`, image prompts, embedded context, HTTP/SSE MCP, and terminal-auth metadata.
- `newSession`, `loadSession`, `unstable_listSessions`, `unstable_forkSession`, `unstable_resumeSession`, `prompt`, `cancel`, `setSessionMode`, `unstable_setSessionModel`.
- Global event subscription converts internal events into ACP `sessionUpdate` notifications.
- Tool permission prompts, tool progress/completion/error updates, plan updates, message/thought chunking, and usage updates are implemented.

Caveat:
- The ACP README still says no streaming, no tool reporting, no mode switching, no terminal support, and weak persistence. Current code implements much of that, so treat the README as stale.

### claude-code-acp

Primary files:
- `/Users/lvpeng/Code/agent-repos/claude-code-acp/src/acp-agent.ts`
- `/Users/lvpeng/Code/agent-repos/claude-code-acp/src/tests/session-config-options.test.ts`

Observed support:
- `initialize` advertises `fork`, `list`, `resume`, image prompts, embedded context, HTTP/SSE MCP, and terminal-auth metadata.
- `newSession`, `loadSession`, `unstable_listSessions`, `unstable_forkSession`, `unstable_resumeSession`, `prompt`, `cancel`, `setSessionMode`, `unstable_setSessionModel`, `setSessionConfigOption`.
- `loadSession` returns `modes`, `models`, and `configOptions`.
- Emits `current_mode_update`, `config_option_update`, `available_commands_update`, message/thought chunks, tool updates, plan, and usage.
- ACP permission flow is implemented.

### auggie

Primary files:
- `/Users/lvpeng/Code/agent-repos/auggie/CHANGELOG.md`
- `/Users/lvpeng/Code/agent-repos/auggie/examples/python-sdk/docs/ARCHITECTURE.md`

Observed support from docs/changelog:
- Changelog says `--acp` is public and no longer experimental.
- Changelog claims terminal auth, model selection, indexing control, file mentions, and image support.
- Example SDK code/docs reference ACP clients and listeners.

Caveat:
- ACP agent implementation itself was not found in the current repo scan, so method-level support is not code-verified from this checkout.

### factory

Primary files:
- `/Users/lvpeng/Code/agent-repos/factory/docs/integrations/zed.mdx`
- `/Users/lvpeng/Code/agent-repos/factory/docs/integrations/jetbrains.mdx`
- `/Users/lvpeng/Code/agent-repos/factory/docs/changelog/cli-updates.mdx`

Observed support from docs/changelog:
- Current docs tell Zed/JetBrains users to launch ACP with `droid exec --output-format acp`.
- Changelog mentions ACP daemon mode and session loading fixes.

Caveat:
- No ACP implementation source surfaced in the public repo scan, so this is documented support, not code-audited support.

### junie

Primary file:
- `/Users/lvpeng/Code/agent-repos/junie/README.md`

Observed support:
- No ACP method names, ACP transport setup, or ACP integration docs were found in the repo scan.
- Current repo contents do not provide a confirmed ACP server path for Agmente.

## Agmente Prioritization

Recommended targets for direct Agmente compatibility testing:
1. `claude-code-acp`
2. `mistral-vibe`
3. `opencode`
4. `kimi-cli`
5. `factory` after runtime validation
6. `auggie` after runtime validation
7. `junie` only if a real ACP server path appears
