# Level 2: nixosTest — 3-node Tor integration test
#
# Nodes:
#   chutney  — runs Chutney hs-v3 network (all Tor DA/relay processes)
#   backend  — SelfPrivacy API + nginx + Tor hidden service
#   client   — Tor client + curl, issues all test assertions via SOCKS
#
# All Tor traffic stays within the QEMU virtual network — no public internet.

{ pkgs, selfprivacy-api, manager }:

let
  # Chutney is a Python package; build it from the Tor Project's git.
  # Replace rev/sha256 after locking: nix-prefetch-git https://gitlab.torproject.org/tpo/core/chutney
  chutney = pkgs.python3Packages.buildPythonApplication {
    pname = "chutney";
    version = "0.0.1-git";
    src = pkgs.fetchgit {
      url = "https://gitlab.torproject.org/tpo/core/chutney.git";
      rev = "main";
      # Replace with the pinned hash from flake.lock after first `nix flake lock`
      sha256 = pkgs.lib.fakeSha256;
    };
    doCheck = false;
  };

  # Custom Chutney hs-v3 network file that binds DAs to 0.0.0.0 so they are
  # reachable from other nixosTest nodes on the shared virtual network.
  chutneyNetwork = pkgs.writeText "hs-v3-selfprivacy" ''
    # Hidden-service v3 network for SelfPrivacy integration tests.
    # DA addresses are set to 0.0.0.0 so they bind on all interfaces
    # and are reachable from the backend and client nodes.

    {"type": "AuthoritativeDirectory", "tag": "da", "Address": "0.0.0.0",
     "count": 3, "portbase": 7000, "orportbase": 5000}
    {"type": "Relay", "tag": "relay", "count": 5, "portbase": 8000,
     "orportbase": 6000}
    {"type": "Client", "tag": "client", "count": 1, "portbase": 9000,
     "SocksPort": 9050}
    {"type": "SomeType", "tag": "hs", "count": 1, "portbase": 10000,
     "hs-version": 3, "HiddenServicePort": "8080"}
  '';

in
{
  name = "tor-integration";

  nodes = {

    # ── chutney node ────────────────────────────────────────────────────────
    chutney =
      { pkgs, ... }:
      {
        environment.systemPackages = [
          pkgs.tor
          chutney
          pkgs.python3
        ];

        users.users.chutney = {
          isNormalUser = true;
          home = "/home/chutney";
          createHome = true;
        };

        # Chutney network is started by the test driver after node is up.
        # See testScript below.
      };

    # ── backend node ────────────────────────────────────────────────────────
    backend =
      { pkgs, lib, ... }:
      {
        imports = [
          selfprivacy-api.nixosModules.default
          # Manager's NixOS config provides nginx path routing + Tor HS setup.
          # Adjust the path if the Manager module layout changes.
          "${manager}/backend/nixos/selfprivacy-tor.nix"
        ];

        # Tor starts with a minimal config; DirServer entries for Chutney DAs
        # are injected at runtime by the test driver (see testScript).
        services.tor = {
          enable = true;
          settings = {
            # HiddenServiceDir and HiddenServicePort are set by the Manager module.
            # Add any additional base settings here.
          };
        };

        # Minimal userdata for the API
        environment.etc."nixos/userdata.json".text = builtins.toJSON {
          username = "admin";
          hashedPassword = "";
          sshKeys = [ ];
          dns.provider = "NONE";
          server.provider = "NONE";
          # domain will be overwritten to the .onion address at test time
          domain = "placeholder.onion";
          autoUpgrade.enable = false;
          timezone = "UTC";
          modules = {
            nextcloud.enable = true;
            gitea.enable = true;
            monitoring.enable = true;
          };
        };

        environment.etc."selfprivacy/secrets.json".text = builtins.toJSON {
          api.token = "test-token-chutney";
        };

        services.redis.package = pkgs.valkey;
        services.redis.servers.sp-api = {
          enable = true;
          save = [ ];
          settings.notify-keyspace-events = "KEA";
        };
      };

    # ── client node ─────────────────────────────────────────────────────────
    client =
      { pkgs, ... }:
      {
        environment.systemPackages = [
          pkgs.tor
          pkgs.curl
          pkgs.openssl
          pkgs.jq
        ];

        # Tor starts with a stub config; DirServer entries for Chutney DAs
        # are injected at runtime by the test driver.
        services.tor = {
          enable = true;
          settings = {
            SocksPort = 9050;
          };
        };
      };
  };

  # ── Test script ────────────────────────────────────────────────────────────
  testScript = ''
    import json
    import time

    start_all()

    # ── 1. Bootstrap Chutney network ─────────────────────────────────────────
    chutney.wait_for_unit("network.target")

    # Copy the custom network file and start the Chutney network
    chutney.succeed("cp ${chutneyNetwork} /home/chutney/hs-v3-selfprivacy")
    chutney.succeed("chown chutney:chutney /home/chutney/hs-v3-selfprivacy")
    chutney.succeed(
        "su -l chutney -c 'chutney start /home/chutney/hs-v3-selfprivacy'"
    )
    chutney.succeed(
        "su -l chutney -c 'chutney wait_for_bootstrap /home/chutney/hs-v3-selfprivacy'"
    )

    # ── 2. Read DA fingerprints and inject DirServer entries ─────────────────
    chutney_ip = chutney.ip_address
    chutney_data_dir = "/home/chutney/.local/share/chutney/nodes"

    dirserver_lines = ["TestingTorNetwork 1"]
    for i, (port_offset, da_name) in enumerate(
        [(0, "da0"), (1, "da1"), (2, "da2")]
    ):
        da_port = 7000 + port_offset
        or_port = 5000 + port_offset
        # Chutney writes a space-separated fingerprint; strip spaces for DirServer
        fp = chutney.succeed(
            f"cat {chutney_data_dir}/{da_name}/fingerprint"
        ).strip().replace(" ", "")
        dirserver_lines.append(
            f'DirServer "{da_name}" orport={or_port} no-v2 {chutney_ip}:{da_port} {fp}'
        )

    tor_config = "\n".join(dirserver_lines)

    backend.succeed(f"printf '%s\\n' {repr(tor_config)} >> /etc/tor/torrc")
    backend.succeed("systemctl restart tor")

    client.succeed(f"printf '%s\\n' {repr(tor_config)} >> /etc/tor/torrc")
    client.succeed("systemctl restart tor")

    # ── 3. Wait for hidden service registration ──────────────────────────────
    backend.wait_for_unit("selfprivacy-api.service")
    backend.wait_until_succeeds(
        "test -f /var/lib/tor/selfprivacy/hostname", timeout=120
    )
    onion = backend.succeed("cat /var/lib/tor/selfprivacy/hostname").strip()

    # Share the VM's TLS cert with the client so curl can verify it
    backend.succeed("cp /etc/selfprivacy/ssl/cert.pem /tmp/backend-cert.pem")
    client.succeed(
        f"scp -o StrictHostKeyChecking=no root@{backend.ip_address}:/tmp/backend-cert.pem /tmp/backend-cert.pem"
    )

    TOKEN = "test-token-chutney"
    SOCKS = f"--socks5-hostname localhost:9050"
    CACERT = "--cacert /tmp/backend-cert.pem"
    URL = f"https://{onion}"

    # ── 4. Wait for Tor circuit to HS ────────────────────────────────────────
    client.wait_until_succeeds(
        f"curl {SOCKS} {CACERT} -sf {URL}/api/version",
        timeout=180,
    )

    # ── T2.1: API version reachable ──────────────────────────────────────────
    version_json = client.succeed(
        f"curl {SOCKS} {CACERT} -sf {URL}/api/version"
    )
    assert '"version"' in version_json, f"T2.1 failed: {version_json}"

    # ── T2.2: GraphQL with valid token ───────────────────────────────────────
    gql_result = client.succeed(
        f"""curl {SOCKS} {CACERT} -sf -X POST {URL}/graphql"""
        f""" -H 'Authorization: Bearer {TOKEN}'"""
        f""" -H 'Content-Type: application/json'"""
        f""" -d '{{"query": "{{ api {{ version }} }}"}}'"""
    )
    data = json.loads(gql_result)
    assert "data" in data and "api" in data["data"], f"T2.2 failed: {gql_result}"

    # ── T2.3: Wrong token rejected ───────────────────────────────────────────
    status = client.succeed(
        f"""curl {SOCKS} {CACERT} -s -o /dev/null -w "%{{http_code}}" -X POST {URL}/graphql"""
        f""" -H 'Authorization: Bearer WRONG'"""
        f""" -H 'Content-Type: application/json'"""
        f""" -d '{{"query": "{{ api {{ version }} }}"}}'"""
    ).strip()
    assert status in ("401", "403"), f"T2.3 failed: expected 401/403, got {status}"

    # ── T2.4: Service URLs are path-based, not subdomain ─────────────────────
    services_result = client.succeed(
        f"""curl {SOCKS} {CACERT} -sf -X POST {URL}/graphql"""
        f""" -H 'Authorization: Bearer {TOKEN}'"""
        f""" -H 'Content-Type: application/json'"""
        f""" -d '{{"query": "{{ services {{ allServices {{ id url }} }} }}"}}'"""
    )
    services_data = json.loads(services_result)
    services = {{
        s["id"]: s["url"]
        for s in services_data["data"]["services"]["allServices"]
        if s.get("url")
    }}

    expected = {{
        "nextcloud": f"{URL}/nextcloud/",
        "gitea": f"{URL}/git/",
        "matrix": f"{URL}/_matrix/",
        "monitoring": f"{URL}/prometheus/",
        "selfprivacy-api": f"{URL}/api/",
    }}
    for svc_id, expected_url in expected.items():
        actual = services.get(svc_id)
        assert actual == expected_url, (
            f"T2.4 failed for {svc_id}: expected {expected_url}, got {actual}"
        )
    # Verify no subdomain-format URL leaked through
    for svc_id, url in services.items():
        if url:
            assert "." + onion not in url, (
                f"T2.4 subdomain leak: {svc_id} url={url}"
            )

    # ── T2.5–T2.9: nginx path reachability ───────────────────────────────────
    # Any status in {200,301,302,401,403,502} confirms nginx routed the path.
    # 404 means nginx routing is broken.
    ROUTED = {"200", "301", "302", "401", "403", "502"}
    paths = [
        ("/api/version", "200"),   # T2.5: API must return 200
        ("/nextcloud/", None),      # T2.6: non-404
        ("/git/", None),            # T2.7: non-404
        ("/_matrix/", None),        # T2.8: non-404
        ("/prometheus/", None),     # T2.9: non-404
    ]
    for path, required_status in paths:
        status = client.succeed(
            f"curl {SOCKS} {CACERT} -s -o /dev/null -w '%{{http_code}}' {URL}{path}"
        ).strip()
        if required_status:
            assert status == required_status, (
                f"T2.5 failed for {path}: expected {required_status}, got {status}"
            )
        else:
            assert status in ROUTED, (
                f"nginx routing broken for {path}: got 404 (or unexpected {status})"
            )

    # ── T2.10: TLS cert SAN matches .onion hostname ───────────────────────────
    cert_info = client.succeed(
        f"echo | openssl s_client -connect {onion}:443"
        f" -proxy localhost:9050 2>/dev/null | openssl x509 -noout -text"
    )
    assert onion in cert_info, (
        f"T2.10 failed: .onion hostname {onion} not in cert SAN"
    )

    print("All Level 2 Tor integration tests passed.")
  '';
}
