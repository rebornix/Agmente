#!/usr/bin/env bash
set -euo pipefail

codex_cmd="${1:-${CODEX_APP_SERVER_CMD:-codex app-server}}"
port="${2:-9000}"
npx_tag="${3:-${AGMENTE_E2E_NPX_TAG:-latest}}"

package_with_tag() {
  local pkg="$1"
  if [[ -n "${npx_tag}" ]]; then
    echo "${pkg}@${npx_tag}"
  else
    echo "${pkg}"
  fi
}

pid_file="/tmp/agmente-e2e-codex-stdio-to-ws-${port}.pid"
log_file="/tmp/agmente-e2e-codex-stdio-to-ws-${port}.log"

if [[ -f "$pid_file" ]]; then
  old_pid="$(cat "$pid_file" || true)"
  if [[ -n "${old_pid}" ]] && kill -0 "$old_pid" 2>/dev/null; then
    kill -9 "$old_pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
fi

pkill -9 -f "stdio-to-ws.*${port}" 2>/dev/null || true

stdio_to_ws_pkg="$(package_with_tag '@rebornix/stdio-to-ws')"
nohup npx -y "$stdio_to_ws_pkg" --persist --grace-period 604800 "$codex_cmd" --port "$port" >"$log_file" 2>&1 &
new_pid="$!"
echo "$new_pid" >"$pid_file"

echo "Started Codex app-server bridge"
echo "Codex command: $codex_cmd"
echo "Port: $port"
echo "NPX tag: ${npx_tag:-<none>}"
echo "PID: $new_pid"
echo "Log: $log_file"
