# Level 2: nixosTest — 3-node Tor integration test
#
# Nodes:
#   das     — three Tor directory authority processes (manual, no Chutney dependency)
#   backend — SelfPrivacy API + nginx + Tor hidden service
#   client  — Tor client (SOCKS 9050) + curl; issues all test assertions
#
# All Tor traffic stays within the QEMU virtual network — no public internet.
# DA keys are generated at runtime; DirServer lines are injected by the testScript.

{ pkgs, selfprivacy-api, ... }:

let
  sp-api-pkg = selfprivacy-api.packages.x86_64-linux.default;
  workerPython = pkgs.python312.withPackages (ps: [
    sp-api-pkg
    ps.huey
  ]);

  # Minimal service definition JSON for templated services.
  # The API reads these from /etc/sp-modules/ to populate allServices.
  mkMinimalServiceDef = id: name: builtins.toJSON {
    meta = {
      id = id;
      name = name;
      description = "Test service ${name}";
      systemdServices = [];
    };
    options = {};
  };
in
{
  name = "tor-integration";

  nodes = {

    # ── das node ─────────────────────────────────────────────────────────────
    # Runs three Tor directory authority (DA) processes.
    # DirPorts (7000-7002) and ORPorts (5000-5002) bind on all interfaces
    # so the backend and client nodes can reach them.
    das = { pkgs, lib, ... }:
    {
      environment.systemPackages = [ pkgs.tor ];

      networking.firewall = {
        enable = true;
        allowedTCPPorts = (lib.range 5000 5002) ++ (lib.range 7000 7002);
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/tor-da/0 0700 root root -"
        "d /var/lib/tor-da/1 0700 root root -"
        "d /var/lib/tor-da/2 0700 root root -"
        "f /var/lib/tor-da/0/dirservers.conf 0600 root root -"
        "f /var/lib/tor-da/1/dirservers.conf 0600 root root -"
        "f /var/lib/tor-da/2/dirservers.conf 0600 root root -"
      ];

      # Generate one systemd service per DA (0, 1, 2).
      # Phase 1 (initial): starts with no DirServer lines → generates keys.
      # Phase 2 (after testScript injects config): restarts with all DirServer lines.
      systemd.services = lib.listToAttrs (lib.map (i:
        lib.nameValuePair "tor-da-${toString i}" {
          description = "Tor directory authority ${toString i}";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" "systemd-tmpfiles-setup.service" ];
          serviceConfig = {
            Type = "simple";
            Restart = "on-failure";
            RestartSec = "3";
            User = "root";
          };
          preStart = ''
            mkdir -p /var/lib/tor-da/${toString i}
            {
              echo "DataDirectory /var/lib/tor-da/${toString i}"
              echo "DirPort 0.0.0.0:${toString (7000 + i)}"
              echo "ORPort 0.0.0.0:${toString (5000 + i)}"
              echo "Nickname da${toString i}"
              echo "AuthoritativeDirectory 1"
              echo "V3AuthoritativeDirectory 1"
              echo "TestingTorNetwork 1"
              echo "DirAllowPrivateAddresses 1"
              echo "ExitPolicyRejectPrivate 0"
              echo "TestingV3AuthVotingInterval 20"
              echo "TestingV3AuthInitialVotingInterval 20"
              echo "TestingV3AuthVotingStartOffset 0"
              echo "TestingV3AuthInitialVoteDelay 5"
              echo "TestingV3AuthInitialDistDelay 5"
              echo "TestingMinExitFlagThreshold 0"
              echo "MinUptimeHidServ 0"
              echo "SocksPort 0"
            } > /var/lib/tor-da/${toString i}/torrc
            if [ -s /var/lib/tor-da/${toString i}/dirservers.conf ]; then
              cat /var/lib/tor-da/${toString i}/dirservers.conf \
                >> /var/lib/tor-da/${toString i}/torrc
            fi
          '';
          script = "${pkgs.tor}/bin/tor -f /var/lib/tor-da/${toString i}/torrc";
        }
      ) [ 0 1 2 ]);
    };

    # ── backend node ──────────────────────���───────────────────────���───────────
    # Runs SelfPrivacy API + nginx + Tor hidden service.
    # The Tor config is stored in /var/lib/tor/ (writable) so DirServer lines
    # can be injected by the testScript without needing to rebuild.
    backend = { pkgs, lib, ... }:
    let
      redis-srv = "sp-api";
    in
    {
      # ── Redis ───────────────────────────────────────────────────────────────
      services.redis.package = pkgs.valkey;
      services.redis.servers.${redis-srv} = {
        enable = true;
        port = 0;  # unix socket only; path /run/redis-sp-api/redis.sock
        save = [ ];
        settings.notify-keyspace-events = "KEA";
      };

      # ── Users ───────────���────────────────────────────────────────────────────
      users.users.selfprivacy-api = {
        isSystemUser = true;
        group = "selfprivacy-api";
      };
      users.groups.selfprivacy-api = { };
      users.groups.redis-sp-api.members = [ "selfprivacy-api" "root" ];

      # ── API service ──────────────────────────────────────────────────────────
      systemd.services.selfprivacy-api = {
        description = "SelfPrivacy GraphQL API";
        after = [ "network-online.target" "redis-${redis-srv}.service" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        environment = {
          HOME = "/root";
          PYTHONUNBUFFERED = "1";
        };
        path = with pkgs; [
          coreutils
          gnutar
          xz.bin
          gzip
          gitMinimal
          iproute2
          util-linux
          nix  # FlakeServiceManager needs `nix eval` for is_installed()
        ];
        serviceConfig = {
          User = "root";
          ExecStart = "${sp-api-pkg}/bin/app.py";
          Restart = "always";
          RestartSec = "5";
        };
      };

      systemd.services.selfprivacy-api-worker = {
        description = "SelfPrivacy API Task Worker";
        after = [ "network-online.target" "redis-${redis-srv}.service" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        environment = {
          HOME = "/root";
          PYTHONUNBUFFERED = "1";
        };
        path = with pkgs; [
          coreutils
          gnutar
          xz.bin
          gzip
          gitMinimal
          iproute2
          util-linux
        ];
        serviceConfig = {
          User = "root";
          ExecStart = "${workerPython}/bin/python -m huey.bin.huey_consumer selfprivacy_api.task_registry.huey";
          Restart = "always";
          RestartSec = "5";
        };
      };

      # ── Tor hidden service (dynamic config, writable at test time) ───────────
      systemd.tmpfiles.rules = [
        "d /var/lib/tor 0700 root root -"
        "d /var/lib/tor/hidden_service 0700 root root -"
        "f /var/lib/tor/dirservers.conf 0600 root root -"
      ];

      systemd.services.selfprivacy-tor = {
        description = "Tor hidden service for SelfPrivacy";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "systemd-tmpfiles-setup.service" ];
        serviceConfig = {
          Type = "simple";
          Restart = "on-failure";
          RestartSec = "3";
          User = "root";
        };
        preStart = ''
          mkdir -p /var/lib/tor/hidden_service
          chmod 700 /var/lib/tor/hidden_service
          {
            echo "DataDirectory /var/lib/tor"
            echo "HiddenServiceDir /var/lib/tor/hidden_service"
            echo "HiddenServicePort 443 127.0.0.1:443"
            echo "SocksPort 0"
            echo "DirAllowPrivateAddresses 1"
            echo "ExitPolicyRejectPrivate 0"
          } > /var/lib/tor/torrc
          if [ -s /var/lib/tor/dirservers.conf ]; then
            cat /var/lib/tor/dirservers.conf >> /var/lib/tor/torrc
          fi
        '';
        script = "${pkgs.tor}/bin/tor -f /var/lib/tor/torrc";
      };

      # ── TLS cert (waits for HS hostname, then embeds it as SAN) ─────────────
      systemd.services.selfprivacy-generate-ssl-cert = {
        description = "Generate self-signed TLS certificate for .onion HTTPS";
        wantedBy = [ "multi-user.target" ];
        after = [ "selfprivacy-tor.service" ];
        before = [ "nginx.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [ pkgs.openssl pkgs.coreutils ];
        script = ''
          CERT_DIR="/etc/ssl/selfprivacy"
          HOSTNAME_FILE="/var/lib/tor/hidden_service/hostname"
          mkdir -p "$CERT_DIR"

          for i in $(seq 1 60); do
            [ -f "$HOSTNAME_FILE" ] && break
            sleep 1
          done

          ONION_HOST=""
          [ -f "$HOSTNAME_FILE" ] && ONION_HOST=$(tr -d '[:space:]' < "$HOSTNAME_FILE")

          SAN="DNS:*.onion"
          [ -n "$ONION_HOST" ] && SAN="DNS:$ONION_HOST,DNS:*.onion"

          openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -days 397 -nodes \
            -keyout "$CERT_DIR/key.pem" \
            -out "$CERT_DIR/cert.pem" \
            -subj "/CN=selfprivacy-tor" \
            -addext "subjectAltName=$SAN" \
            -addext "basicConstraints=critical,CA:TRUE"
          chmod 644 "$CERT_DIR/cert.pem"
          chmod 640 "$CERT_DIR/key.pem"
          echo "Generated TLS cert with SAN=$SAN"
        '';
      };

      # ── nginx reverse proxy ────────────────────────────────────���──────────────
      services.nginx = {
        enable = true;
        virtualHosts."onion" = {
          listen = [ { addr = "0.0.0.0"; port = 443; ssl = true; } ];
          default = true;
          onlySSL = true;
          sslCertificate = "/etc/ssl/selfprivacy/cert.pem";
          sslCertificateKey = "/etc/ssl/selfprivacy/key.pem";

          locations."/graphql" = {
            proxyPass = "http://127.0.0.1:5050";
            extraConfig = ''
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
            '';
          };
          locations."/api" = {
            proxyPass = "http://127.0.0.1:5050";
            extraConfig = "proxy_set_header Host $host;";
          };
          locations."/prometheus" = {
            proxyPass = "http://127.0.0.1:9001";
            extraConfig = "proxy_set_header Host $host;";
          };
          locations."/nextcloud/" = {
            proxyPass = "http://127.0.0.1:8081/";
            extraConfig = "proxy_set_header Host $host;";
          };
          locations."= /nextcloud" = { return = "301 /nextcloud/"; };
          locations."/git/" = {
            proxyPass = "http://127.0.0.1:3000/";
            extraConfig = "proxy_set_header Host $host;";
          };
          locations."= /git" = { return = "301 /git/"; };
          locations."/_matrix" = {
            proxyPass = "http://127.0.0.1:8008";
            extraConfig = "proxy_set_header Host $host;";
          };
        };
      };

      systemd.services.nginx.after = [ "selfprivacy-generate-ssl-cert.service" ];
      systemd.services.nginx.wants = [ "selfprivacy-generate-ssl-cert.service" ];

      networking.firewall = {
        enable = true;
        # Port 443: nginx TLS; 8080: temporary HTTP cert server for test setup
        allowedTCPPorts = [ 443 8080 ];
      };

      environment.systemPackages = with pkgs; [
        curl
        openssl
        tor
        jq
        python3
      ];

      # ── Service metadata files (/etc/sp-modules/) ───────��────────────────────
      # The API reads these to populate allServices. Read-only is fine (only reads).
      environment.etc."sp-modules/nextcloud".text =
        mkMinimalServiceDef "nextcloud" "Nextcloud";
      environment.etc."sp-modules/gitea".text =
        mkMinimalServiceDef "gitea" "Gitea";
      environment.etc."sp-modules/matrix".text =
        mkMinimalServiceDef "matrix" "Matrix";

      # ── Nix experimental features (required by FlakeServiceManager's nix eval) ─
      nix.settings.experimental-features = [ "nix-command" "flakes" ];

      # ── Userdata: written as a real file (not symlink) so it's writable ──────
      # The testScript updates the domain field to the actual .onion address.
      system.activationScripts.selfprivacy-userdata = {
        deps = [ ];
        text =
          let
            initialUserdata = pkgs.writeText "userdata.json" (builtins.toJSON {
              username = "admin";
              hashedPassword = "";
              sshKeys = [ ];
              dns.provider = "NONE";
              server.provider = "NONE";
              domain = "placeholder.onion";
              autoUpgrade.enable = false;
              timezone = "UTC";
              modules = {
                nextcloud.enable = true;
                gitea.enable = true;
                monitoring.enable = true;
              };
            });
          in
          ''
            mkdir -p /etc/nixos
            # Remove symlink if environment.etc created one, then write real file
            [ -L /etc/nixos/userdata.json ] && rm /etc/nixos/userdata.json
            [ -f /etc/nixos/userdata.json ] || {
              cp ${initialUserdata} /etc/nixos/userdata.json
              chmod 644 /etc/nixos/userdata.json
            }
            # FlakeServiceManager (tor-support branch) reads /etc/nixos/sp-modules/flake.nix.
            # Without it, TemplatedService.is_installed() raises FileNotFoundError and
            # the entire allServices GraphQL query fails.
            mkdir -p /etc/nixos/sp-modules
            if [ ! -f /etc/nixos/sp-modules/flake.nix ]; then
              cat > /etc/nixos/sp-modules/flake.nix << 'EONIX'
{
  description = "SelfPrivacy NixOS PoC modules/extensions/bundles/packages/etc";

  inputs.nextcloud.url = "git+https://git.selfprivacy.org/SelfPrivacy/selfprivacy-nixos-config.git?ref=flakes&dir=sp-modules/nextcloud";
  inputs.gitea.url = "git+https://git.selfprivacy.org/SelfPrivacy/selfprivacy-nixos-config.git?ref=flakes&dir=sp-modules/gitea";
  inputs.matrix.url = "git+https://git.selfprivacy.org/SelfPrivacy/selfprivacy-nixos-config.git?ref=flakes&dir=sp-modules/matrix";

  outputs = _: { };
}
EONIX
            fi
          '';
      };

      # ── Secrets: initial API token (read by write_token_to_redis migration) ──
      # Only READ by the API, so a read-only environment.etc is fine.
      environment.etc."selfprivacy/secrets.json".text = builtins.toJSON {
        api.token = "test-token-chutney";
      };
    };

    # ── client node ─────────��─────────────────────────────────────────────────
    # Tor client with SOCKS on port 9050. DirServer lines injected by testScript.
    client = { pkgs, ... }:
    {
      environment.systemPackages = with pkgs; [ tor curl openssl jq ];

      systemd.tmpfiles.rules = [
        "d /var/lib/tor-client 0700 root root -"
        "f /var/lib/tor-client/dirservers.conf 0600 root root -"
      ];

      systemd.services.selfprivacy-tor-client = {
        description = "Tor client for SelfPrivacy tests";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "systemd-tmpfiles-setup.service" ];
        serviceConfig = {
          Type = "simple";
          Restart = "on-failure";
          RestartSec = "3";
          User = "root";
        };
        preStart = ''
          {
            echo "DataDirectory /var/lib/tor-client"
            echo "SocksPort 9050"
            echo "DirAllowPrivateAddresses 1"
            echo "ExitPolicyRejectPrivate 0"
          } > /var/lib/tor-client/torrc
          if [ -s /var/lib/tor-client/dirservers.conf ]; then
            cat /var/lib/tor-client/dirservers.conf >> /var/lib/tor-client/torrc
          fi
        '';
        script = "${pkgs.tor}/bin/tor -f /var/lib/tor-client/torrc";
      };
    };
  };

  # ── Test script ──────────────────────────────────────────────────────────────
  testScript = ''
    import json
    import base64

    start_all()

    # ── 1. Wait for DA key generation ────────────────────────────────────────
    das.wait_for_unit("network.target")

    for i in range(3):
        das.wait_until_succeeds(
            f"test -f /var/lib/tor-da/{i}/fingerprint",
            timeout=120
        )

    # ── 2. Read DA fingerprints and build DirServer config ───────────────────
    das_ip = das.ip_address

    dirserver_lines = [
        "TestingTorNetwork 1",
        "DirAllowPrivateAddresses 1",
        "ExitPolicyRejectPrivate 0",
    ]
    for i in range(3):
        da_port = 7000 + i
        or_port = 5000 + i
        fp_line = das.succeed(
            f"cat /var/lib/tor-da/{i}/fingerprint"
        ).strip()
        # Tor writes fingerprint as "Nickname AABB CCDD ..." or "Nickname AABBCCDD..."
        # Join all parts after the nickname and strip spaces to get 40-char hex.
        parts = fp_line.split()
        fp = "".join(parts[1:])
        dirserver_lines.append(
            f'DirServer "da{i}" orport={or_port} no-v2 {das_ip}:{da_port} {fp}'
        )

    tor_config = "\n".join(dirserver_lines)

    # ── 3. Inject DirServer config into all DAs and restart ─────────────────
    # Encode as base64 to safely transfer multi-line config via shell command.
    tor_config_b64 = base64.b64encode(tor_config.encode()).decode()
    for i in range(3):
        das.succeed(
            f"echo '{tor_config_b64}' | base64 --decode > /var/lib/tor-da/{i}/dirservers.conf"
        )
        das.succeed(f"systemctl restart tor-da-{i}")

    for i in range(3):
        das.wait_for_unit(f"tor-da-{i}")

    # ── 4. Inject DirServer config into backend and client ───────────────────
    backend.succeed(
        f"echo '{tor_config_b64}' | base64 --decode > /var/lib/tor/dirservers.conf"
    )
    backend.succeed("systemctl restart selfprivacy-tor")

    client.succeed(
        f"echo '{tor_config_b64}' | base64 --decode > /var/lib/tor-client/dirservers.conf"
    )
    client.succeed("systemctl restart selfprivacy-tor-client")

    # ── 5. Wait for HS hostname (implies DA consensus formed) ────────────────
    backend.wait_until_succeeds(
        "test -f /var/lib/tor/hidden_service/hostname",
        timeout=300,
    )
    onion = backend.succeed(
        "cat /var/lib/tor/hidden_service/hostname"
    ).strip()

    # ── 5b. Regenerate TLS cert with the real onion SAN ──────────────────────
    # The cert service ran at boot BEFORE the HS hostname was available, so it
    # used the DNS:*.onion fallback.  Now that we have the real address, restart
    # it so the cert contains DNS:{onion} — required for T2.10 and for curl's
    # wildcard-refusal on bare-TLD patterns.
    backend.succeed("systemctl restart selfprivacy-generate-ssl-cert.service")
    backend.wait_for_unit("selfprivacy-generate-ssl-cert.service", timeout=120)
    backend.wait_until_succeeds(
        "test -f /etc/ssl/selfprivacy/cert.pem",
        timeout=30,
    )
    # Reload nginx so it serves the new cert (file path unchanged, content updated).
    backend.succeed("systemctl reload nginx")

    # ── 6. Update backend userdata to use the real .onion domain ─────────────
    # /etc/nixos/userdata.json is a writable real file (created by activationScript).
    backend.succeed(
        f"""python3 -c "
import json
with open('/etc/nixos/userdata.json') as f:
    d = json.load(f)
d['domain'] = '{onion}'
with open('/etc/nixos/userdata.json', 'w') as f:
    json.dump(d, f)
" """
    )
    backend.succeed("systemctl restart selfprivacy-api")
    backend.wait_for_unit("selfprivacy-api.service")

    # ── 7. Share TLS cert with client (Python HTTP, backend port 8080) ───────
    backend.succeed(
        "python3 -m http.server 8080 --directory /etc/ssl/selfprivacy &"
    )
    client.succeed(
        f"curl -sf http://{backend.ip_address}:8080/cert.pem -o /tmp/backend-cert.pem"
    )

    # ── 8. Wait for Tor circuit to the hidden service ───────���─────────────────
    TOKEN = "test-token-chutney"
    SOCKS = "--socks5-hostname localhost:9050"
    CACERT = "--cacert /tmp/backend-cert.pem"
    URL = f"https://{onion}"

    client.wait_until_succeeds(
        f"curl {SOCKS} {CACERT} -sf {URL}/api/version",
        timeout=300,
    )

    # ── T2.1: API version endpoint reachable via Tor ──────────────────────────
    version_json = client.succeed(
        f"curl {SOCKS} {CACERT} -sf {URL}/api/version"
    )
    assert '"version"' in version_json, f"T2.1 failed: {version_json}"

    # ── T2.2: GraphQL query with valid token ──────────────────────────────────
    gql_result = client.succeed(
        f"curl {SOCKS} {CACERT} -sf -X POST {URL}/graphql"
        f" -H 'Authorization: Bearer {TOKEN}'"
        f" -H 'Content-Type: application/json'"
        f" -d '{{\"query\": \"{{ api {{ version }} }}\"}}'",
    )
    data = json.loads(gql_result)
    assert "data" in data and "api" in data["data"], f"T2.2 failed: {gql_result}"

    # ── T2.3: Wrong token is rejected ─────────────────────��───────────────────
    status = client.succeed(
        f"curl {SOCKS} {CACERT} -s -o /dev/null -w '%{{http_code}}' -X POST {URL}/graphql"
        f" -H 'Authorization: Bearer WRONG'"
        f" -H 'Content-Type: application/json'"
        f" -d '{{\"query\": \"{{ api {{ version }} }}\"}}'",
    ).strip()
    assert status in ("401", "403"), f"T2.3 failed: expected 401/403, got {status}"

    # ── T2.4: allServices URLs are path-based (not subdomain) for .onion ─────
    services_result = client.succeed(
        f"curl {SOCKS} {CACERT} -sf -X POST {URL}/graphql"
        f" -H 'Authorization: Bearer {TOKEN}'"
        f" -H 'Content-Type: application/json'"
        f" -d '{{\"query\": \"{{ services {{ allServices {{ id url }} }} }}\"}}'",
    )
    services_data = json.loads(services_result)
    services = {{
        s["id"]: s["url"]
        for s in services_data["data"]["services"]["allServices"]
        if s.get("url")
    }}

    expected = {{
        "nextcloud":      f"{URL}/nextcloud/",
        "gitea":          f"{URL}/git/",
        "matrix":         f"{URL}/_matrix/",
        "monitoring":     f"{URL}/prometheus/",
        "selfprivacy-api": f"{URL}/api/",
    }}
    for svc_id, expected_url in expected.items():
        actual = services.get(svc_id)
        assert actual == expected_url, (
            f"T2.4 failed for {svc_id}: expected {expected_url!r}, got {actual!r}"
        )
    # No subdomain-format URL should appear for any service
    for svc_id, url in services.items():
        if url:
            assert f".{onion}" not in url, (
                f"T2.4 subdomain leak: {svc_id} url={url!r}"
            )

    # ── T2.5–T2.9: nginx path reachability (non-404 = routing works) ─────────
    ROUTED = {{"200", "301", "302", "401", "403", "502"}}
    path_checks = [
        ("/api/version",  "200"),  # T2.5: API must return 200
        ("/nextcloud/",   None),   # T2.6: non-404 (502 ok if NC not running)
        ("/git/",         None),   # T2.7: non-404
        ("/_matrix/",     None),   # T2.8: non-404
        ("/prometheus/",  None),   # T2.9: non-404
    ]
    for path, required_status in path_checks:
        status = client.succeed(
            f"curl {SOCKS} {CACERT} -s -o /dev/null -w '%{{http_code}}' {URL}{path}"
        ).strip()
        if required_status:
            assert status == required_status, (
                f"T2.5 failed for {path}: expected {required_status}, got {status}"
            )
        else:
            assert status in ROUTED, (
                f"nginx routing broken for {path}: got {status!r} (expected one of {ROUTED})"
            )

    # ── T2.10: TLS cert SAN contains the actual .onion hostname ──────────────
    cert_info = backend.succeed(
        "openssl x509 -in /etc/ssl/selfprivacy/cert.pem -noout -text"
    )
    assert onion in cert_info, (
        f"T2.10 failed: {onion!r} not found in cert SAN:\n{cert_info[:500]}"
    )

    print("All Level 2 Tor integration tests passed.")
  '';
}
