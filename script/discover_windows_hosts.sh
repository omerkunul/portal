#!/usr/bin/env bash
set -euo pipefail

PORTS="${PORTAL_DISCOVERY_PORTS:-22 445 3389}"

default_iface="$(route get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
if [[ -z "${default_iface:-}" ]]; then
  echo "Could not determine the default network interface." >&2
  exit 1
fi

local_ip="$(ipconfig getifaddr "$default_iface" 2>/dev/null || true)"
if [[ -z "$local_ip" ]]; then
  echo "Could not determine local IP for interface $default_iface." >&2
  exit 1
fi

subnet="${local_ip%.*}"

echo "Scanning $subnet.0/24 from $default_iface ($local_ip)..."
echo "Ports checked: $PORTS"
echo

for host in "$subnet".{1..254}; do
  [[ "$host" == "$local_ip" ]] && continue

  (
    ping -q -c 1 -W 200 "$host" >/dev/null 2>&1 || exit 0

    open_ports=()
    for port in $PORTS; do
      if nc -G 1 -z "$host" "$port" >/dev/null 2>&1; then
        open_ports+=("$port")
      fi
    done

    name="$(dig +short -x "$host" 2>/dev/null | sed 's/\.$//' | head -1 || true)"
    if [[ ${#open_ports[@]} -gt 0 ]]; then
      printf "%-15s ports=%-12s %s\n" "$host" "${open_ports[*]}" "$name"
    fi
  ) &

  while (( $(jobs -pr | wc -l | tr -d ' ') >= 32 )); do
    wait -n 2>/dev/null || true
  done
done

wait

echo
echo "Use the host with port 22 open for remote build/install:"
echo "  ./script/install_windows_remote.sh user@windows-ip"
