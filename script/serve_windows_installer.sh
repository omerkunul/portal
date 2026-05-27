#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
ZIP="$DIST_DIR/Portal-Windows-installer.zip"
PORT="${PORTAL_INSTALLER_PORT:-8123}"

if [[ ! -f "$ZIP" ]]; then
  cat >&2 <<EOF
Missing installer package:
  $ZIP

Create it first with:
  .\\windows\\package-windows-installer.ps1
EOF
  exit 1
fi

default_iface="$(route get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
local_ip="$(ipconfig getifaddr "$default_iface" 2>/dev/null || true)"

if [[ -z "$local_ip" ]]; then
  echo "Could not determine the Mac LAN IP." >&2
  exit 1
fi

url="http://$local_ip:$PORT/Portal-Windows-installer.zip"

cat <<EOF
Serving Portal Windows installer:
  $url

Run this on the Windows machine in PowerShell:

  \$zip="\$env:TEMP\\Portal-Windows-installer.zip"; \$dir="\$env:TEMP\\Portal-Windows-installer"; Invoke-WebRequest "$url" -OutFile \$zip; Unblock-File \$zip; Remove-Item -Recurse -Force \$dir -ErrorAction SilentlyContinue; Expand-Archive -Force \$zip \$dir; Get-ChildItem \$dir -Recurse | Unblock-File; Set-Location \$dir; powershell -NoProfile -ExecutionPolicy Bypass -File .\\install-portal.ps1 -Launch

Press Ctrl+C here when the download is done.
EOF

cd "$DIST_DIR"
python3 -m http.server "$PORT" --bind 0.0.0.0
