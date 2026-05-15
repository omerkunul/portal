#!/usr/bin/env bash
set -euo pipefail

PLIST="/Library/LaunchDaemons/local.portal.awdlguard.plist"
TMP_PLIST="$(mktemp)"

cleanup() {
  rm -f "$TMP_PLIST"
}
trap cleanup EXIT

cat > "$TMP_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.portal.awdlguard</string>
  <key>ProgramArguments</key>
  <array>
    <string>/sbin/ifconfig</string>
    <string>awdl0</string>
    <string>down</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>/tmp/portal-awdlguard.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/portal-awdlguard.err</string>
</dict>
</plist>
PLIST

sudo cp "$TMP_PLIST" "$PLIST"
sudo chown root:wheel "$PLIST"
sudo chmod 644 "$PLIST"

sudo launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
sudo launchctl bootstrap system "$PLIST"
sudo launchctl kickstart -k system/local.portal.awdlguard
sudo /sbin/ifconfig awdl0 down || true

echo "Portal AWDL guard installed. awdl0 will be kept down every 30 seconds."
