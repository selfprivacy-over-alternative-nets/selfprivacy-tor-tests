# SelfPrivacy-over-Tor — Handover Document

**Date:** 2026-08-03
**Project root:** `/home/a/git/personal/selfprivacy/`

---

## 1. What This Project Is

SelfPrivacy is a NixOS self-hosting platform. This project adds **Tor .onion access** so users
with no public IP / firewall access can reach their instance over Tor. Four tasks:

| Task | What | Status |
|------|------|--------|
| 1 | API changes — onion URL routing, nginx path routing, GraphQL, Tor HS service | **DONE** |
| 2 | Test infrastructure — selfprivacy-tor-tests repo, 3-level test plan | **DONE** |
| 3 | Run all tests, fix papercuts | **DONE** — all 3 automated suites pass (see §3) |
| 4 | Upstream PR to git.selfprivacy.org | **NOT STARTED** — user action (see §6) |

**Remaining = user actions only:** Level 3 manual E2E (Flutter/Android) and the upstream PR.

---

## 2. Repos, Branches, Latest Commits (all pushed)

```
selfprivacy-api            /home/a/git/personal/selfprivacy/selfprivacy-api
  remote  git@github.com:selfprivacy-over-alternative-nets/selfprivacy-api.git
  branch  tor-support
  HEAD    91462d2f  fix: await async get_users() in onion-routing user-repo test   (Level 1 fix)

selfprivacy-tor-tests      /home/a/git/personal/selfprivacy/selfprivacy-tor-tests
  remote  git@github.com:selfprivacy-over-alternative-nets/selfprivacy-tor-tests.git
  branch  main
  HEAD    4fec551   docs: fill in how_to_test_what.md
          1035837   fix(level2): make tor-integration and https-integration tests pass  (the big one)

Manager (Flutter app)      /home/a/git/personal/selfprivacy/Manager-Ubuntu-SelfPrivacy-Over-alternative-nets
  remote  git@github.com:selfprivacy-over-alternative-nets/Manager-Ubuntu-SelfPrivacy-Over-alternative-nets.git
```

Both working trees are clean and pushed. Detailed notes/gotchas are also in Claude's memory file
`project-selfprivacy-tor` (auto-loaded each session).

---

## 3. Test Status — ALL AUTOMATED TESTS PASS

| Group | Where | IDs | Result |
|-------|-------|-----|--------|
| Level 1 unit (URL routing logic) | selfprivacy-api | T1.1–T1.17 | **23 passed** |
| Level 2 tor-integration (real onion over a private Tor net) | selfprivacy-tor-tests | T2.1–T2.10 | **all pass** |
| Level 2 https-integration (subdomain HTTPS) | selfprivacy-tor-tests | T3.1–T3.8 | **all pass** |

### How to run / re-verify

```bash
# Level 1  (~2 min + VM)
cd /home/a/git/personal/selfprivacy/selfprivacy-api
nix run .#pytest-vm -- tests/test_onion_routing.py -v          # look for "23 passed"

# Level 2 tor + https  (~10–25 min each under TCG; see §5 for speed)
cd /home/a/git/personal/selfprivacy/selfprivacy-tor-tests
nix build .#checks.x86_64-linux.tor-integration   --no-link -L # "All Level 2 Tor integration tests passed."
nix build .#checks.x86_64-linux.https-integration --no-link -L # "HTTPS integration tests: ALL PASSED"
```

Prefix with `NIX_CONFIG="experimental-features = nix-command flakes"` if flakes aren't globally on.
Plain-language description of what each group checks: `selfprivacy-tor-tests/how_to_test_what.md`.

---

## 4. Hard-Won Knowledge (do NOT re-derive)

Most of Task 3 was fixing bugs that only surfaced on a full run. Full detail is in commit
`1035837` and the memory file; the essentials:

- **sanic flaky test** (already fixed at api `f690f70f`, do not touch): `disabledTestPaths ++ [...]`
  via a `mkPkgs` overlay in `selfprivacy-api/flake.nix`. `doCheck=false` does nothing (sanic uses
  `doInstallCheck`). Verified `1829 passed, 26 deselected`.
- **The Tor test network was rebuilt from scratch** (tor-integration.nix). A working private Tor
  net needs: `tor-gencert` for v3 authority keys; `DirAuthority` lines with `v3ident` + relay
  fingerprint; `V3AuthVoteDelay+DistDelay < half VotingInterval`; **extra relays** beyond the 3
  authorities + `EnforceDistinctSubnets 0`; and `AssumeReachable 1` + `TestingDirAuthVote{Guard,
  Exit,HSDir} *` to escape the fresh-network "0% guard bandwidth" deadlock. Keygen runs as one
  oneshot; tor services are gated with `ConditionPathExists=/var/lib/tor-da/dirservers.conf`;
  das/backend get more cores/RAM or backdoor.service's serial console times out.
- **Nix `''…''` gotchas**: a literal `''` inside a testScript string terminates it; col-0 lines
  defeat the `''` dedent (this indented a shell here-doc delimiter and froze the https VM at
  switch-root — fixed by using `pkgs.writeText`+`cp` instead of here-docs). NixOS test `Machine`
  has **no `.ip_address`** — use `getent ahostsv4 <node>`.
- **Auth over GraphQL**: this API returns **HTTP 200 with an `errors` body** for a bad token (not
  401/403), and `api.version` is a **public** field — so auth tests must query an authenticated
  field like `{ system { __typename } }`.
- **The API is slow to bind 5050** (imports strawberry): use generous `wait_for_open_port` /
  `wait_for_unit` timeouts (180–600 s), especially under TCG.

---

## 5. Environment gotchas (bit us repeatedly)

- **KVM vs TCG.** `nix build .#checks.*` runs VMs in the `nixbld` sandbox, which **cannot open
  /dev/kvm** (nixbld isn't in the `kvm` group; `/dev/kvm` is `other::---`) → slow **TCG** emulation
  (2.5-min boots, ~100-s api starts). All tests still pass, just slowly. To go fast:
  `sudo setfacl -m g:nixbld:rw /dev/kvm`, **or** run the driver as the user (who has KVM):
  `nix run .#level2-tor-run` / `nix run .#level2-https-run` (non-interactive driver packages added
  to the flake). `nix run .#pytest-vm` already runs as the user → KVM.
- **Stray QEMU VMs block later runs.** A leftover VM holds the test VLAN socket, so the next VM
  hangs at "start all VLans" with no error. If a run stalls there:
  `pkill -KILL -f qemu-system; pkill -KILL -f nixos-test-driver` and retry.
- **Detached runs of `nix run .#…driver`** need real stdio — `setsid … </dev/null` kills them at
  "start all VLans". Use the Bash tool's `run_in_background`, or `nix build .#checks.*`.
- **Capturing exit codes:** `nix build … 2>&1 | tail` masks failures (tail exits 0). Use
  `nix build … --no-link -L > /tmp/x.log 2>&1; echo "EXIT:$?" >> /tmp/x.log`; check `EXIT:0`.

---

## 6. Remaining Work (USER ACTIONS)

### 6a. Level 3 E2E — Flutter (desktop) + Android, manual
Steps in `/home/a/git/personal/selfprivacy/test_plan.md` §9 (T3.1–T3.9) and §10 (T4.1–T4.7).
Uses the real app in `Manager-…-Over-alternative-nets/` against a test server over Tor:
```bash
cd Manager-Ubuntu-SelfPrivacy-Over-alternative-nets/
./build-and-run.sh --app-linux                 # Ubuntu
# nix develop -c ./build-and-run.sh --app-linux  # NixOS
```
Onion + token come from the running backend VM (`/var/lib/tor/selfprivacy/hostname`,
`/etc/selfprivacy/secrets.json`). Note: `test_plan.md` describes a **Chutney** setup, but the
automated Level 2 tests use a **self-contained** Tor net (no Chutney) — for a manual E2E you still
need a Tor test net or Chutney to reach the .onion.

### 6b. Upstream PR to git.selfprivacy.org
Instructions in `selfprivacy-api/UPSTREAM_PR.md`. PR diff = only the Python + unit-test changes on
`tor-support` (test infra stays in selfprivacy-tor-tests).

### Also NOT covered by any test yet (would need manual checking)
Adding/removing a service; actually logging into Nextcloud and storing a file; backups
(enable → run → restore). Email is intentionally excluded (can't work over Tor).

---

## 7. User Preferences (for Claude)

- **Ask before running sudo** — run sudo only if absolutely necessary; otherwise ask the user.
- Automated tests must be **fully deterministic** — no public Tor network.
- Work **autonomously** until everything passes or a real blocker needs the user; don't stop early.
- Commit/push only when asked. Prefers **concise** output and docs.
```
