# How to test what

Three **automated** groups (run a command, get pass/fail) and one **by-hand** group.

## What each group checks (plain words)

- **Group 1 — right links** (T1.1–T1.17, `selfprivacy-api`): the app builds the correct link for
  every service — files (Nextcloud), code (Git), calls (Jitsi), chat (Matrix), dashboard, control
  panel — on both a secret Tor `.onion` and a normal domain, and reads your user list.
- **Group 2 — private, over Tor** (T2.1–T2.10): builds a mini private Tor network and checks your
  `.onion` answers, the **right** key gets in, a **wrong** key is refused, every service opens (no
  "page not found"), and the connection is secured (certificate matches).
- **Group 3 — normal domain** (T3.1–T3.8): the other way to reach your server — your own domain
  with a **subdomain per service** (`cloud.yourname.com` for files, `git.yourname.com` for code, …)
  instead of Tor's paths. Checks each subdomain routes right, login works, wrong login refused, and
  the certificate covers your domain + sub-names. *(A real server uses a Let's Encrypt certificate
  here; the test uses a self-signed stand-in + fake local DNS, so no internet is needed.)*
- **Group 4 — real app, by hand** (desktop T3.x / Android T4.x; steps in `../test_plan.md` §9–10):
  a person opens the actual app, connects over Tor, and clicks through Services / System / Users,
  opens Nextcloud + dashboard, and reconnects after a restart.

## NOT tested yet (do by hand)
Adding/removing a service; actually logging into Nextcloud and storing a file; backups
(enable → run → restore); email (excluded — can't work over Tor).

## Run it

**Set up once — Ubuntu:**
```bash
sh <(curl -L https://nixos.org/nix/install) --daemon      # then open a NEW terminal
export NIX_CONFIG="experimental-features = nix-command flakes"
sudo apt-get install -y git
```
**NixOS:** run only `export NIX_CONFIG="experimental-features = nix-command flakes"`, and prefix
each `git` below with `nix shell nixpkgs#git -c`.

**Get the code:**
```bash
cd ~
git clone --branch tor-support https://github.com/selfprivacy-over-alternative-nets/selfprivacy-api.git
git clone https://github.com/selfprivacy-over-alternative-nets/selfprivacy-tor-tests.git
```

**Run the tests** — each box below is one real command; paste and run it (these run the tests,
they do **not** open the app):

Group 1 — right links (~2 min):
```bash
cd ~/selfprivacy-api && nix run .#pytest-vm -- tests/test_onion_routing.py -v
```
Group 2 — private, over Tor (~10–25 min):
```bash
cd ~/selfprivacy-tor-tests && nix build .#checks.x86_64-linux.tor-integration --no-link -L
```
Group 3 — normal domain (~5–15 min):
```bash
cd ~/selfprivacy-tor-tests && nix build .#checks.x86_64-linux.https-integration --no-link -L
```
The very first run also builds the server from source (one-time, +20–40 min).

## Did it pass?
Passed if it ends with **no** red `error:` line. You'll see `23 passed` (G1),
`All Level 2 Tor integration tests passed.` (G2), or `HTTPS integration tests: ALL PASSED` (G3).

## Faster (optional)
Sandbox VMs use slow emulation. For hardware acceleration (KVM): add yourself to the `kvm` group
and run `nix run .#level2-tor-run` / `.#level2-https-run` instead of the `nix build` lines, or
`sudo setfacl -m g:nixbld:rw /dev/kvm`.
