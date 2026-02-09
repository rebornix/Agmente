#!/usr/bin/env bash
set -euo pipefail

simulator_id="${1:?Usage: cleanup.sh <simulator_id> [port] [bundle_id]}"
port="${2:-9000}"
bundle_id="${3:-com.example.Agmente}"

pid_file="/tmp/agmente-e2e-stdio-to-ws-${port}.pid"

if [[ -f "$pid_file" ]]; then
  pid="$(cat "$pid_file" || true)"
  if [[ -n "${pid}" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
fi

pkill -9 -f "stdio-to-ws.*${port}" 2>/dev/null || true
xcrun simctl uninstall "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true

echo "Cleanup complete"
echo "Simulator: $simulator_id"
echo "Port: $port"
echo "Bundle: $bundle_id"
