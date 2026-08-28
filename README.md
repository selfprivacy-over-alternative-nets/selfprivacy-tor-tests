# SelfPrivacy-over-Tor — Integration Tests

Test infrastructure for the SelfPrivacy-over-Tor and SelfPrivacy-HTTPS projects.

## Levels

| Level | Location | Description |
|-------|----------|-------------|
| 1 | `selfprivacy-api/tests/` | Python unit tests (run inside the API flake) |
| 2 | `tests/level2/` | NixOS VM tests (`pkgs.testers.runNixOSTest`) |
| 3 | `tests/level3/` | E2E scripts for real hardware / VirtualBox |

### How the levels map to the usage scenarios

The Manager repo (`Manager-Ubuntu-SelfPrivacy-Over-Tor`) documents the supported deployment
scenarios — **Method 1** (Ubuntu + VirtualBox backend, scenarios **S.A**) and **Method 2** (native
NixOS backend, scenarios **S.B / S.C**), with the app on Linux or Android (**S.D**). The test levels
cover them as follows:

| Level | Validates | Scenarios |
|-------|-----------|-----------|
| 1 | URL/onion routing logic in the API — backend-agnostic, no VM | underpins all scenarios |
| 2 | The **native-NixOS backend** (Tor + HTTPS modules) end-to-end in an automated NixOS VM | Method 2 backend (**S.B / S.C**) |
| 3 | The **full stack against the real app / browser** over a Tor test net | Method 1 backend + clients (**S.A**, **S.D**); a native variant exists too |

Level 3 has one script per backend method: `setup-chutney-vbox.sh` (Method 1, VirtualBox) and
`setup-chutney-nixos-native.sh` (Method 2, native NixOS).

## Level 1 (Python unit tests — fast, no VM)

Level 1 lives in the API repo and runs in an ephemeral NixOS VM with Redis (via the API flake's
`pytest-vm` helper). From the **selfprivacy-api** checkout:

```bash
cd ../selfprivacy-api      # the selfprivacy-api repo (sibling checkout)
nix run .#pytest-vm -- tests/test_onion_routing.py -v      # expect "23 passed"
```

`pytest-vm` accepts any pytest arguments; run the whole suite with `nix run .#pytest-vm`.

## Level 2 (nixosTest — automated, runs in CI)

### Prerequisites

```bash
# One-time: update the manager flake input to latest commit
# (needed to get selfprivacy-https-core.nix)
nix flake update manager
```

> **Note:** `flake.lock` may be pinned to an older manager commit.
> Running `nix flake update manager` refreshes the lock to the latest
> `main` branch commit, which includes `selfprivacy-https-core.nix`.
> CI does this automatically before each run.

### Run all Level 2 tests

```bash
# Build (non-interactive, logs output):
nix build .#checks.x86_64-linux.tor-integration --no-link -L
nix build .#checks.x86_64-linux.https-integration --no-link -L
```

### Interactive test driver (for debugging)

```bash
# Tor test
nix run .#packages.x86_64-linux.level2-driver

# HTTPS test
nix run .#packages.x86_64-linux.level2-https-driver
```

Inside the driver REPL:
```python
start_all()
backend.wait_for_unit("selfprivacy-api.service")
# ... run individual test steps
```

## Level 3 (E2E — manual)

Scripts in `tests/level3/` require a running VirtualBox VM created by
the Manager's `./build-and-run.sh` script:

| Script | Purpose |
|--------|---------|
| `setup-chutney-vbox.sh` | Start Chutney Tor network + socat bridges to VBox VM |
| `setup-chutney-nixos-native.sh` | Same but for a native NixOS host |
| `cleanup-socat.sh` | Stop Chutney + clean up socat processes |

## Android

`android/setup-emulator.sh` — start an Android emulator with SOCKS5 Tor proxy forwarding.

Requires Android SDK with `emulator` and `adb` in `PATH`.

## CI

GitHub Actions matrix (`.github/workflows/ci.yml`):
- `tor-integration` — Tor hidden service API and routing tests (T2.1–T2.10)
- `https-integration` — HTTPS subdomain routing tests (T3.1–T3.8)

Runs on every push/PR to `main`. Each job:
1. Installs Nix with `nix-command` + `flakes`
2. Enables KVM for QEMU acceleration
3. Runs `nix flake update manager` (keeps manager lock current)
4. Builds the NixOS test derivation

## Test IDs

| ID | Test | File |
|----|------|------|
| T1.1–T1.17 | Unit tests: Tor URL routing logic | `selfprivacy-api/tests/test_onion_routing.py` |
| T2.1–T2.10 | Level 2: Tor hidden service integration | `tests/level2/tor-integration.nix` |
| T3.1–T3.8 | Level 2: HTTPS subdomain routing integration | `tests/level2/https-integration.nix` |
