#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-${PORTAL_WIN_TARGET:-${LANFLOW_WIN_TARGET:-}}}"
REMOTE_DIR="${PORTAL_WIN_REMOTE_DIR:-${LANFLOW_WIN_REMOTE_DIR:-PortalBuild}}"
LOCAL_OUT="$ROOT_DIR/dist/windows"

if [[ -z "$TARGET" ]]; then
  cat >&2 <<'USAGE'
Usage:
  ./script/build_windows_remote.sh user@windows-ip

Optional:
  export PORTAL_WIN_TARGET=user@windows-ip
  export PORTAL_WIN_REMOTE_DIR=PortalBuild
USAGE
  exit 2
fi

command -v ssh >/dev/null || { echo "ssh is required" >&2; exit 1; }
command -v scp >/dev/null || { echo "scp is required" >&2; exit 1; }

mkdir -p "$LOCAL_OUT"

echo "Preparing remote build folder on $TARGET..."
ssh "$TARGET" "powershell -NoProfile -ExecutionPolicy Bypass -Command \"Remove-Item -Recurse -Force '$REMOTE_DIR' -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force '$REMOTE_DIR' | Out-Null\""

echo "Copying Windows project..."
scp -q -r "$ROOT_DIR/windows" "$TARGET:$REMOTE_DIR/"

echo "Building Windows exe remotely..."
ssh "$TARGET" "powershell -NoProfile -ExecutionPolicy Bypass -Command \"Set-Location '$REMOTE_DIR'; .\\windows\\build-windows-exe.ps1\""

echo "Fetching exe..."
scp -q "$TARGET:$REMOTE_DIR/dist/windows/PortalWindows.exe" "$LOCAL_OUT/PortalWindows.exe"

echo "Built: $LOCAL_OUT/PortalWindows.exe"
