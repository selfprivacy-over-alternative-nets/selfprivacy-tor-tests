#!/usr/bin/env bash
# setup-chutney-vbox.sh — Bridge Chutney DAs to VirtualBox VM for Level 3 E2E tests
#
# Prerequisites:
#   - Chutney running: ./chutney start networks/hs-v3
#   - VirtualBox VM running with host-only adapter (vboxnet0) already attached
#   - socat installed
#
# What this does:
#   1. Reads Chutney DA ports from the running network
#   2. Uses socat to forward each DA port from vboxnet0 IP to 127.0.0.1
#   3. Injects TestingTorNetwork + DirServer entries into the VM's /etc/tor/torrc via SSH
#   4. Restarts Tor inside the VM
#
# After this script, the VM's Tor will use the local Chutney network.
# Flutter on the host uses Chutney SOCKS at 127.0.0.1:9050.
set -euo pipefail

VM_SSH_PORT="${VM_SSH_PORT:-2222}"
CHUTNEY_DATA_DIR="${CHUTNEY_DATA_DIR:-$HOME/.local/share/chutney/nodes}"
HOST_ONLY_IP="${HOST_ONLY_IP:-192.168.56.1}"
DA_BASE_PORT="${DA_BASE_PORT:-7000}"
OR_BASE_PORT="${OR_BASE_PORT:-5000}"
DA_COUNT=3

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o PubkeyAuthentication=no -o PreferredAuthentications=password \
  -o LogLevel=ERROR"

# ── 1. Start socat forwarders ──────────────────────────────────────────────
echo "Starting socat forwarders on $HOST_ONLY_IP..."
for i in $(seq 0 $((DA_COUNT - 1))); do
    PORT=$((DA_BASE_PORT + i))
    socat TCP-LISTEN:$PORT,bind=$HOST_ONLY_IP,reuseaddr,fork TCP:127.0.0.1:$PORT &
    echo "  socat: $HOST_ONLY_IP:$PORT -> 127.0.0.1:$PORT (pid $!)"
done

# Store socat PIDs for cleanup
SOCAT_PIDS=$(pgrep -f "socat TCP-LISTEN.*$HOST_ONLY_IP" || true)
echo "$SOCAT_PIDS" > /tmp/selfprivacy-socat.pids
echo "socat PIDs saved to /tmp/selfprivacy-socat.pids (run cleanup.sh to stop)"

# ── 2. Build DirServer config ──────────────────────────────────────────────
echo "Reading DA fingerprints from Chutney..."
TOR_CONFIG="TestingTorNetwork 1"

for i in $(seq 0 $((DA_COUNT - 1))); do
    DA_NAME="da$i"
    DA_PORT=$((DA_BASE_PORT + i))
    OR_PORT=$((OR_BASE_PORT + i))
    FP_FILE="$CHUTNEY_DATA_DIR/$DA_NAME/fingerprint"
    if [ ! -f "$FP_FILE" ]; then
        echo "ERROR: fingerprint file not found: $FP_FILE"
        echo "Is Chutney running? Run: ./chutney start networks/hs-v3"
        exit 1
    fi
    # Fingerprint may have spaces; strip them
    FP=$(tr -d ' ' < "$FP_FILE")
    TOR_CONFIG="$TOR_CONFIG
DirServer \"$DA_NAME\" orport=$OR_PORT no-v2 $HOST_ONLY_IP:$DA_PORT $FP"
done

# ── 3. Inject config into VM ───────────────────────────────────────────────
echo "Injecting Tor config into VM (port $VM_SSH_PORT)..."
sshpass -p '' ssh $SSH_OPTS -p $VM_SSH_PORT root@localhost << EOF
printf '%s\n' "$TOR_CONFIG" >> /etc/tor/torrc
systemctl restart tor
echo "Tor restarted with Chutney DirServer entries."
EOF

echo ""
echo "Done. VM Tor is now connected to local Chutney network."
echo "Flutter on the host uses SOCKS at 127.0.0.1:9050 (Chutney client SOCKS)."
echo ""
echo "To stop socat forwarders: $(dirname "$0")/cleanup-socat.sh"
