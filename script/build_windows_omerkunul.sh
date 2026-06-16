#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${PORTAL_WIN_TARGET:-}" ]]; then
  echo "Set PORTAL_WIN_TARGET to user@windows-ip before using this helper." >&2
  exit 1
fi

exec "$SCRIPT_DIR/build_windows_remote.sh" "$PORTAL_WIN_TARGET"
