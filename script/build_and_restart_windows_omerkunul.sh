#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/build_windows_omerkunul.sh"
"$SCRIPT_DIR/restart_windows_omerkunul.sh"
