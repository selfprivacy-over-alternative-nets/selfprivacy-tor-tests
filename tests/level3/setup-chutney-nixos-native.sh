#!/usr/bin/env bash
# setup-chutney-nixos-native.sh — Configure local Tor for Chutney (C2c: NixOS native)
#
# Use when the SelfPrivacy backend runs DIRECTLY on this NixOS machine (no VirtualBox).
# Chutney is already running on the same machine, so DAs are at 127.0.0.1.
# No bridging or socat needed.
#
# Prerequisites:
#   - Chutney running: ./chutney start networks/hs-v3
#   - Tor service running (selfprivacy Tor, not a separate system Tor)
set -euo pipefail

CHUTNEY_DATA_DIR="${CHUTNEY_DATA_DIR:-$HOME/.local/share/chutney/nodes}"
DA_BASE_PORT="${DA_BASE_PORT:-7000}"
OR_BASE_PORT="${OR_BASE_PORT:-5000}"
DA_COUNT=3
TORRC="${TORRC:-/etc/tor/torrc}"

if [ ! -d "$CHUTNEY_DATA_DIR/da0" ]; then
    echo "ERROR: Chutney data dir not found: $CHUTNEY_DATA_DIR"
    echo "Is Chutney running? Run: ./chutney start networks/hs-v3"
    exit 1
fi

echo "Building DirServer config for local Chutney..."
TOR_CONFIG="TestingTorNetwork 1"

for i in $(seq 0 $((DA_COUNT - 1))); do
    DA_NAME="da$i"
    DA_PORT=$((DA_BASE_PORT + i))
    OR_PORT=$((OR_BASE_PORT + i))
    FP_FILE="$CHUTNEY_DATA_DIR/$DA_NAME/fingerprint"
    FP=$(tr -d ' ' < "$FP_FILE")
    TOR_CONFIG="$TOR_CONFIG
DirServer \"$DA_NAME\" orport=$OR_PORT no-v2 127.0.0.1:$DA_PORT $FP"
done

echo "Injecting into $TORRC..."
printf '%s\n' "$TOR_CONFIG" | sudo tee -a "$TORRC" > /dev/null
sudo systemctl restart tor

echo "Done. Local Tor is now connected to Chutney network."
echo "Flutter uses SOCKS at 127.0.0.1:9050 (Chutney client SOCKS)."
