# selfprivacy-tor-tests — notes for Claude

The integration tests of SelfPrivacy-over-Tor and SelfPrivacy-HTTPS, by level (see the Levels table in `README.md`).
Their results feed the test matrix in the `dev-dashboard` repo.

- ⛔ Only full, from-scratch, new-user runs count as a test result (the cardinal testing rule).
- Commands are written in full, with every argument explicit — no hidden defaults that change what is tested.
- The `manager` flake input pins the `Manager-Ubuntu-SelfPrivacy-Over-Tor` repo; bump it with `nix flake update` when
  that repo changes.

The work's context — handovers, decisions, Claude's memory — is in the private repo `selfprivacy-context`, cloned next to
this one. This repo is **public**: never commit IP addresses, onion addresses, tokens, passwords or your domain; check
with `python3 ../selfprivacy-context/tools/scan_sensitive.py --deny /home/a/selfprivacy-private/redaction-map.txt <files>`.
