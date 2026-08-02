#!/usr/bin/env bash
# cleanup-socat.sh — Stop socat forwarders started by setup-chutney-vbox.sh
set -euo pipefail

PIDS_FILE="/tmp/selfprivacy-socat.pids"

if [ -f "$PIDS_FILE" ]; then
    while read -r pid; do
        kill "$pid" 2>/dev/null && echo "Stopped socat pid $pid" || true
    done < "$PIDS_FILE"
    rm "$PIDS_FILE"
else
    # Fallback: kill all socat processes matching our pattern
    pkill -f "socat TCP-LISTEN" || true
    echo "Stopped all socat TCP-LISTEN processes."
fi
