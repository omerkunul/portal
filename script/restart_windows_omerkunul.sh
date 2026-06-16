#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${PORTAL_WIN_TARGET:-}" ]]; then
  echo "Set PORTAL_WIN_TARGET to user@windows-ip before using this helper." >&2
  exit 1
fi

ssh -o BatchMode=yes "$PORTAL_WIN_TARGET" \
  'powershell -NoProfile -ExecutionPolicy Bypass -Command "schtasks /Run /TN PortalRestart"'
