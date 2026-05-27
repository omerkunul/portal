#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-${PORTAL_WIN_TARGET:-}}"
ZIP="$ROOT_DIR/dist/Portal-Windows-installer.zip"
REMOTE_DIR="${PORTAL_WIN_INSTALLER_DIR:-PortalInstaller}"

if [[ -z "$TARGET" ]]; then
  cat >&2 <<'USAGE'
Usage:
  ./script/install_windows_remote.sh user@windows-ip

Optional:
  export PORTAL_WIN_TARGET=user@windows-ip
USAGE
  exit 2
fi

if [[ ! -f "$ZIP" ]]; then
  cat >&2 <<EOF
Missing installer package:
  $ZIP

Build/package it on Windows first, or copy a current installer into dist.
EOF
  exit 1
fi

command -v ssh >/dev/null || { echo "ssh is required" >&2; exit 1; }
command -v scp >/dev/null || { echo "scp is required" >&2; exit 1; }

echo "Copying installer to $TARGET..."
ssh "$TARGET" "powershell -NoProfile -ExecutionPolicy Bypass -Command \"Remove-Item -Recurse -Force '$REMOTE_DIR' -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force '$REMOTE_DIR' | Out-Null\""
scp -q "$ZIP" "$TARGET:$REMOTE_DIR/Portal-Windows-installer.zip"

echo "Installing Portal on Windows..."
ssh "$TARGET" "powershell -NoProfile -ExecutionPolicy Bypass -Command \"Set-Location '$REMOTE_DIR'; Expand-Archive -Force Portal-Windows-installer.zip .; .\\install-portal.ps1 -Launch\""

echo "Installed Portal on $TARGET."
echo "If a Windows user is signed in, the PortalLaunch task should open the visible app."
