#!/usr/bin/env bash
set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/portal-awdl"
TMP_FILE="$(mktemp)"

cleanup() {
  rm -f "$TMP_FILE"
}
trap cleanup EXIT

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  USER_NAME="$SUDO_USER"
else
  USER_NAME="$(stat -f '%Su' /dev/console)"
fi

if [[ -z "$USER_NAME" || "$USER_NAME" == "root" ]]; then
  echo "Could not determine the logged-in user for the sudoers rule." >&2
  exit 1
fi

cat > "$TMP_FILE" <<EOF
# Allow Portal to toggle only the AWDL interface without prompting every time.
${USER_NAME} ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 down, /sbin/ifconfig awdl0 up
EOF

sudo chown root:wheel "$TMP_FILE"
sudo chmod 440 "$TMP_FILE"
sudo visudo -cf "$TMP_FILE" >/dev/null
sudo cp "$TMP_FILE" "$SUDOERS_FILE"

echo "Portal AWDL sudoers rule installed for ${USER_NAME}."
echo "The Portal app can now toggle awdl0 without asking for a password."
