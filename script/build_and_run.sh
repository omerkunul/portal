#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Portal"
PRODUCT_NAME="PortalMac"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/$PRODUCT_NAME"

pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true
swift build --package-path "$ROOT_DIR/mac/PortalMac" -c release

BUILD_BIN="$ROOT_DIR/mac/PortalMac/.build/release/$PRODUCT_NAME"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_BIN" "$EXECUTABLE"
chmod +x "$EXECUTABLE"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>PortalMac</string>
  <key>CFBundleIdentifier</key>
  <string>local.portal.mac</string>
  <key>CFBundleName</key>
  <string>Portal</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Portal uses accessibility input events to control this Mac from your Windows mouse and keyboard.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${PORTAL_CODESIGN_IDENTITY:-${LANFLOW_CODESIGN_IDENTITY:-}}"
if [[ -n "$SIGN_IDENTITY" ]] && /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F "$SIGN_IDENTITY" >/dev/null; then
  /usr/bin/codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
else
  /usr/bin/codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

if [[ "${1:-}" == "--verify" ]]; then
  /usr/bin/open -n "$APP_DIR"
  sleep 1
  pgrep -x "$PRODUCT_NAME" >/dev/null
  echo "Launched $APP_DIR"
else
  /usr/bin/open -n "$APP_DIR"
fi
