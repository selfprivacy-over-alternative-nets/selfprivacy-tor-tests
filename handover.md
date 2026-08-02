# SelfPrivacy-over-Tor — Handover Document

**Date:** 2026-08-02  
**Project root:** `/home/a/git/personal/selfprivacy/`

---

## 1. What This Project Is

SelfPrivacy is a NixOS self-hosting platform. This project adds **Tor .onion access** to it, so
users with no public IP or firewall restrictions can reach their SelfPrivacy instance over Tor.

The work spans four tasks:

| Task | What | Status |
|------|------|--------|
| 1 | API changes — onion URL routing, nginx path routing, GraphQL mutations, Tor HS service | **DONE** |
| 2 | Test infrastructure — 3-level test plan, selfprivacy-tor-tests repo | **DONE** |
| 3 | Run all tests, fix papercuts | **IN PROGRESS** (see §4) |
| 4 | Upstream PR to git.selfprivacy.org | **NOT STARTED** (user action, see §6) |

---

## 2. Repos and Branches

### 2a. selfprivacy-api (API fork)

```
Local:   /home/a/git/personal/selfprivacy/selfprivacy-api
Remote:  https://github.com/selfprivacy-over-alternative-nets/selfprivacy-api.git
Branch:  tor-support
HEAD:    f690f70f  fix: use disabledTestPaths list to skip flaky sanic timeout test
```

Key commits on `tor-support`:
```
f690f70f  fix: use disabledTestPaths list to skip flaky sanic timeout test   ← CORRECT sanic fix
e7bd7c4a  fix: skip sanic flaky timeout test to unblock nixpkgs build         ← wrong (doCheck=false)
1b1cbffa  docs: add upstream PR submission guide (Task 4)
ecf33761  refactor: extract TOR_SERVICE_PATHS to onion_routing.py; add unit tests
c5ee7a96  feat: add Tor .onion subpath URL routing support
```

### 2b. selfprivacy-tor-tests (test infra, NEW repo)

```
Local:   /home/a/git/personal/selfprivacy/selfprivacy-tor-tests
Remote:  https://github.com/selfprivacy-over-alternative-nets/selfprivacy-tor-tests.git  (assumed)
Branch:  main
HEAD:    3d28998  fix: eliminate race conditions in tor-integration testScript
```

Key commits on `main`:
```
3d28998  fix: eliminate race conditions in tor-integration testScript
86aa2a9  chore: bump selfprivacy-api to correct sanic test fix (disabledTestPaths)
f1aa939  fix: correct Python dict/set literals in tor-integration testScript
ea83492  chore: bump selfprivacy-api to pick up sanic test-skip fix
9b0e2fc  fix: merge packages.x86_64-linux into single attrset to avoid duplicate attr
```

### 2c. Manager (Flutter app, upstream project)

```
Local:   /home/a/git/personal/selfprivacy/Manager-Ubuntu-SelfPrivacy-Over-alternative-nets
Remote:  https://github.com/selfprivacy-over-alternative-nets/Manager-Ubuntu-SelfPrivacy-Over-alternative-nets.git
Branch:  main
```

---

## 3. Hard-Won Technical Knowledge (do not re-derive these)

### 3a. sanic-25.x flaky test — the root cause of ALL build failures

sanic 25.12.0 has a timing-sensitive test `test_keep_alive_client_timeout` in
`test_keep_alive_timeout.py` that fails inside the Nix sandbox with `assert 2 == 1` (timing skew).

**Critical facts:**
- sanic uses `doInstallCheck` (not `doCheck`), so `doCheck = false` does NOTHING
- `disabledTestPaths` is a Nix **list**, not a string — `+` fails with "cannot coerce a list to a string"
- Correct fix in `selfprivacy-api/flake.nix`:

```nix
mkPkgs = system: import nixpkgs {
  inherit system;
  overlays = [(final: prev: {
    python312Packages = prev.python312Packages.overrideScope (_: pprev: {
      sanic = pprev.sanic.overrideAttrs (old: {
        disabledTestPaths = old.disabledTestPaths
          ++ [ "test_keep_alive_timeout.py" ];
      });
    });
  })];
};
```

Then replace all `nixpkgs.legacyPackages.${system}` with `mkPkgs system` in `packages` and
`checks` sections. (`legacyPackages` does not accept overlays — must use `import nixpkgs {overlays=[...]}`.)

This is **already in the code at `f690f70f`** and **already committed**. Do not change it.

**Verification:** sanic completed with `1829 passed, 26 deselected` (the 26 deselected are the
`test_keep_alive_timeout.py` tests — confirmed working).

### 3b. Python `{{}}` in Nix `''...''` strings

In a Nix multiline string `''...''`, `{{` and `}}` produce **literal `{{` and `}}`** in the
output Python — they do NOT produce single `{` and `}`. This is the opposite of Python f-strings.

- **Outside f-strings** (dict/set literals): use single `{` and `}`
- **Inside f-strings** (e.g. `-d '{{\"query\": ...}}'`): `{{` correctly escapes to `{` → leave those alone

This bug was already fixed in `selfprivacy-tor-tests/tests/level2/tor-integration.nix` at commit `f1aa939`.

### 3c. Race conditions in tor-integration.nix testScript

Two race conditions were fixed in `3d28998`:

1. After `systemctl restart selfprivacy-api`: wait for both unit AND port
   ```python
   backend.succeed("systemctl restart selfprivacy-api")
   backend.wait_for_unit("selfprivacy-api.service")
   backend.wait_for_open_port(5050, timeout=60)  # must come after
   ```

2. After starting HTTP server in background:
   ```python
   backend.succeed("python3 -m http.server 8080 --directory /etc/ssl/selfprivacy &")
   backend.wait_for_open_port(8080, timeout=30)  # must come before client curl
   client.succeed(f"curl -sf http://{backend.ip_address}:8080/cert.pem -o /tmp/backend-cert.pem")
   ```

### 3d. Capturing nix build exit codes

`nix build ... 2>&1 | tail -30` always exits 0 (tail's exit code), masking failures.

**Always** use this pattern:
```bash
nix build ... --no-link --print-build-logs > /tmp/some.log 2>&1
echo "EXIT:$?" >> /tmp/some.log
```

Then check with `grep "EXIT:" /tmp/some.log` — `EXIT:0` = success.

---

## 4. Current Build Status

### SITUATION: Both builds were interrupted when the Claude session context was summarized.

The two background build processes (`bsxj40xr4` and `bawxkzuvn`) were killed mid-run. The log files
end with `error: interrupted by the user` and contain no `EXIT:` line.

**Good news:** sanic already completed and its result is cached in `/nix/store/`. It will not
rebuild. strawberry-graphql was at ~21% when killed — it will resume from its Nix cache checkpoint.

### 4a. Restart Level 2 tor-integration (FIRST — takes ~15-25 min)

```bash
cd /home/a/git/personal/selfprivacy/selfprivacy-tor-tests
NIX_CONFIG="experimental-features = nix-command flakes" \
nix build .#checks.x86_64-linux.tor-integration \
  --no-link --print-build-logs \
  > /tmp/tor-integration-build.log 2>&1
echo "EXIT:$?" >> /tmp/tor-integration-build.log
```

Run this in background. The test will:
1. Build strawberry-graphql (partially cached, ~5-10 min)
2. Build selfprivacy-api package (~2 min)
3. Build NixOS VMs for chutney, backend, client nodes (~5 min)
4. Run the 3-node QEMU nixosTest with assertions T2.1–T2.10

Success looks like: `EXIT:0` at end of log, and the last few lines mentioning the test passing.

### 4b. Restart Level 1 pytest-vm (SECOND — starts after 4a's sanic/strawberry build completes)

```bash
cd /home/a/git/personal/selfprivacy/selfprivacy-api
NIX_CONFIG="experimental-features = nix-command flakes" \
nix run .#pytest-vm -- tests/test_onion_routing.py -v \
  > /tmp/pytest-vm-level1.log 2>&1
echo "EXIT:$?" >> /tmp/pytest-vm-level1.log
```

Tests T1.1–T1.17 as defined in `/home/a/git/personal/selfprivacy/test_plan.md` §7.

### 4c. Level 2 https-integration (AFTER 4a passes)

```bash
cd /home/a/git/personal/selfprivacy/selfprivacy-tor-tests
NIX_CONFIG="experimental-features = nix-command flakes" \
nix build .#checks.x86_64-linux.https-integration \
  --no-link --print-build-logs \
  > /tmp/https-integration-build.log 2>&1
echo "EXIT:$?" >> /tmp/https-integration-build.log
```

---

## 5. If a Test Fails

### Debugging Level 2 (nixosTest)

**Interactive mode** — starts QEMU VMs with a Python shell:
```bash
cd /home/a/git/personal/selfprivacy/selfprivacy-tor-tests
NIX_CONFIG="experimental-features = nix-command flakes" \
nix run .#level2-driver -- --interactive
```

**Build just the driver** (fast, no test execution):
```bash
NIX_CONFIG="experimental-features = nix-command flakes" \
nix build .#packages.x86_64-linux.level2-driver --no-link
```

**Read the full test script:**
```
/home/a/git/personal/selfprivacy/selfprivacy-tor-tests/tests/level2/tor-integration.nix
```

### Debugging Level 1

```bash
cd /home/a/git/personal/selfprivacy/selfprivacy-api
pytest tests/test_onion_routing.py -v  # host Python, no VM, fastest iteration
```

Key source files:
- `selfprivacy_api/services/service.py` — `Service.get_url()`
- `selfprivacy_api/services/templated_service.py` — `TemplatedService.get_url()`
- `selfprivacy_api/services/onion_routing.py` — `TOR_SERVICE_PATHS` dict
- `tests/test_onion_routing.py` — T1.1–T1.17

---

## 6. Remaining Work (all passing tests unlock these)

### 6a. Level 3 E2E Flutter tests (USER ACTION — manual)

After Level 2 passes, the user runs the Flutter app manually. From
`/home/a/git/personal/selfprivacy/test_plan.md` §9:

```bash
cd Manager-Ubuntu-SelfPrivacy-Over-alternative-nets/
./build-and-run.sh --app-linux   # Ubuntu
# OR: nix develop -c ./build-and-run.sh --app-linux  # NixOS
```

Enter the onion address shown in the backend VM (from
`/var/lib/tor/selfprivacy/hostname`) and the API token from
`/etc/selfprivacy/secrets.json`. Test cases T3.1–T3.9.

For development/testing without the full VM stack, use:
- Onion address: `uok24ygehb2wcdxetrcb5wrpwxspanbmhwdp3pxzn6thcqgh63edbiad.onion`
- Token: `test-token-for-tor-development`

### 6b. Upstream PR to git.selfprivacy.org (USER ACTION)

Full instructions in `/home/a/git/personal/selfprivacy/selfprivacy-api/UPSTREAM_PR.md`.

Summary:
1. Fork `https://git.selfprivacy.org/SelfPrivacy/selfprivacy-rest-api`
2. Push the `tor-support` branch as `upstream-pr/tor-onion-routing`
3. Open PR. The PR diff is only the Python + unit test changes (no test infra — that lives in selfprivacy-tor-tests).

---

## 7. Full Test Plan Reference

`/home/a/git/personal/selfprivacy/test_plan.md`

Quick reference of test IDs:
- **T1.1–T1.9**: `Service.get_url()` with `.onion` vs normal domain
- **T1.10**: `TemplatedService` with `showUrl=false` → `None`
- **T1.11–T1.12**: `ServiceManager.get_url()` with both domain types
- **T1.13–T1.14**: `Prometheus.get_url()`
- **T1.15–T1.17**: User repository provider assertions
- **T2.1–T2.3**: Connectivity + auth over Tor SOCKS
- **T2.4**: All service URLs are onion-path format (zero subdomain URLs)
- **T2.5–T2.9**: nginx path routing (no 404s)
- **T2.10**: TLS cert SAN matches `.onion` hostname
- **T3.1–T3.9**: Flutter E2E (manual)
- **T4.1–T4.7**: Android E2E (manual, optional)

---

## 8. flake.lock Pin State

`selfprivacy-tor-tests/flake.lock` (HEAD `86aa2a9`) pins:
- `selfprivacy-api` → `f690f70f` (correct — sanic fix via `disabledTestPaths`)
- `nixpkgs` (tor-tests) → `6d65bfc1` (nixos-26.05)
- `nixpkgs_2` (selfprivacy-api's nixpkgs) → `8eeec934` (nixos-26.05, slightly older pin)

Do **not** update the pin unless there is a specific reason — the current combination is known-working for sanic.

---

## 9. User Preferences (for Claude)

- Run sudo commands only if absolutely necessary; ask the user to run them otherwise.
- All tests must be fully deterministic — no public Tor network in automated tests.
- User was on a walk; work autonomously until everything passes or a blocker requires user input.
- Do not stop until the project is completely done.
