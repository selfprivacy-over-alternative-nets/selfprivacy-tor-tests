#!/usr/bin/env bash
# setup-emulator.sh — Start Android emulator and configure SOCKS for Chutney
#
# Prerequisites (Ubuntu):
#   sudo usermod -aG kvm $USER  (log out/in after)
#   kvm-ok                       (must print "KVM acceleration can be used")
#   ./scripts/requirements.sh --app-android  (from Manager repo)
#
# Prerequisites (NixOS):
#   boot.kernelModules = [ "kvm-amd" ]  (or kvm-intel) in configuration.nix
#   users.users.<name>.extraGroups = [ "kvm" ]
#   nix develop  (provides Android SDK)
#
# Usage:
#   ./android/setup-emulator.sh             # start emulator (default AVD name)
#   ./android/setup-emulator.sh usb         # use USB-connected device instead
set -euo pipefail

AVD_NAME="${AVD_NAME:-selfprivacy-test}"
SOCKS_PORT="${SOCKS_PORT:-9050}"
MODE="${1:-emulator}"

# ── Verify KVM ────────────────────────────────────────────────────────────
if [ "$MODE" = "emulator" ]; then
    if ! groups | grep -q kvm; then
        echo "ERROR: current user is not in the 'kvm' group."
        echo "Ubuntu:  sudo usermod -aG kvm \$USER  (then log out/in)"
        echo "NixOS:   add users.users.<name>.extraGroups = [ \"kvm\" ] to config"
        exit 1
    fi

    if command -v kvm-ok &>/dev/null; then
        kvm-ok || { echo "ERROR: KVM not available."; exit 1; }
    fi

    # ── Start emulator ───────────────────────────────────────────────────
    if [ -z "${ANDROID_HOME:-}" ]; then
        echo "ERROR: ANDROID_HOME is not set. Run 'nix develop' or install Android SDK."
        exit 1
    fi

    echo "Starting emulator AVD: $AVD_NAME ..."
    "$ANDROID_HOME/emulator/emulator" -avd "$AVD_NAME" -no-audio &
    EMULATOR_PID=$!
    echo "Emulator PID: $EMULATOR_PID"

    echo "Waiting for device to boot..."
    adb wait-for-device
    # Wait for full boot
    until adb shell getprop sys.boot_completed 2>/dev/null | grep -q "^1$"; do
        sleep 2
    done
    echo "Emulator booted."
else
    echo "USB device mode. Confirm device is connected with USB debugging enabled:"
    adb devices
fi

# ── adb reverse: route device localhost:SOCKS_PORT → host Chutney SOCKS ──
echo "Setting up adb reverse tcp:$SOCKS_PORT tcp:$SOCKS_PORT ..."
adb reverse tcp:$SOCKS_PORT tcp:$SOCKS_PORT
echo "Device localhost:$SOCKS_PORT now routes to host 127.0.0.1:$SOCKS_PORT (Chutney SOCKS)"

# ── Trust VM cert on device ───────────────────────────────────────────────
MANAGER_DIR="${MANAGER_DIR:-$(dirname "$0")/../..}"
if [ -f "$MANAGER_DIR/scripts/trust-cert-android.sh" ]; then
    echo "Trusting VM TLS cert on device..."
    bash "$MANAGER_DIR/scripts/trust-cert-android.sh"
else
    echo "WARNING: trust-cert-android.sh not found at $MANAGER_DIR/scripts/"
    echo "Run manually: ./build-and-run.sh --trust-cert-android"
fi

echo ""
echo "Ready. Deploy the app with:"
echo "  cd Manager-Ubuntu-SelfPrivacy-Over-Tor && ./build-and-run.sh --app-android"
echo ""
echo "NOTE: Flutter app must use localhost:$SOCKS_PORT for SOCKS proxy (not 10.0.2.2)."
