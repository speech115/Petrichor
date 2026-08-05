#!/usr/bin/env bash
# Print the identifier of the single connected iOS device.
# Fails loudly when none or several are connected, because guessing which phone
# to install onto is worse than stopping.
set -euo pipefail

tmp=$(mktemp -t petrichor-devices)
trap 'rm -f "$tmp"' EXIT

xcrun devicectl list devices --json-output "$tmp" >/dev/null

python3 - "$tmp" <<'PY'
import json, sys

devices = json.load(open(sys.argv[1]))["result"]["devices"]
# A wired iPhone that has not been touched yet reports tunnelState
# "disconnected" — the tunnel is established lazily by the first devicectl
# operation. Only "unavailable" means the device is truly unreachable.
connected = [
    d for d in devices
    if d["hardwareProperties"].get("platform") == "iOS"
    and d["connectionProperties"].get("tunnelState") != "unavailable"
]

if not connected:
    sys.exit("No connected iPhone. Plug it in, unlock it, and trust this Mac.")
if len(connected) > 1:
    names = ", ".join(
        f'{d["deviceProperties"].get("name")} ({d["identifier"]})' for d in connected
    )
    sys.exit(f"Several iPhones connected: {names}. Disconnect all but one.")

print(connected[0]["identifier"])
PY
