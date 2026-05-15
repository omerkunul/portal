#!/usr/bin/env bash
set -euo pipefail

ssh -o BatchMode=yes omerkunul@192.168.1.27 \
  'powershell -NoProfile -ExecutionPolicy Bypass -Command "schtasks /Run /TN PortalRestart"'
