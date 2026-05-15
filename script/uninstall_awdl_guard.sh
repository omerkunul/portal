#!/usr/bin/env bash
set -euo pipefail

PLIST="/Library/LaunchDaemons/local.portal.awdlguard.plist"

sudo launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
sudo rm -f "$PLIST"

if [[ "${1:-}" == "--enable-awdl" ]]; then
  sudo /sbin/ifconfig awdl0 up || true
  echo "Portal AWDL guard removed and awdl0 was enabled."
else
  echo "Portal AWDL guard removed. awdl0 current state was left unchanged."
fi
