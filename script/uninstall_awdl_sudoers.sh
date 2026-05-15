#!/usr/bin/env bash
set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/portal-awdl"

sudo rm -f "$SUDOERS_FILE"

echo "Portal AWDL sudoers rule removed."
