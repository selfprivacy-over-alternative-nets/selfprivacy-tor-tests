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
  # Build the worker env from the api package's OWN python interpreter.
  # sp-api-pkg is built against the selfprivacy-api flake's nixpkgs, which
  # differs from this test's `pkgs`; using `pkgs.python312` here mixes two
  # nixpkgs and makes `import selfprivacy_api` fail (ModuleNotFoundError).
  workerPython = sp-api-pkg.pythonModule.withPackages (ps: [
    sp-api-pkg
    ps.huey
  ]);

  # Bogus DirAuthority line used at first boot (phase 1). A Tor node only
  # accepts a private IP address if it does NOT use the default directory
  # authorities, so every Tor instance needs at least one custom DirAuthority
  # line even before the real ones (with v3ident + relay fingerprint) are
  # injected by the testScript. Replaced by /…/dirservers.conf once present.
  torPlaceholder =
    "DirAuthority ph orport=5000 no-v2 "
    + "v3ident=0000000000000000000000000000000000000000 "
    + "10.0.0.1:7000 1111111111111111111111111111111111111111";

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
    let
      torBin = "${pkgs.tor}/bin/tor";
      gencert = "${pkgs.tor}/bin/tor-gencert";
      # A v3 directory authority will not start without pre-generated identity/
      # signing keys + certificate (tor-gencert), and a Tor relay on a private
      # IP needs a custom DirAuthority line (torPlaceholder) to boot. Three
      # authorities alone cannot host an onion service (path selection fails
      # with "invalid selected path"), so we also run three plain relays to
      # enlarge the circuit pool. EnforceDistinctSubnets 0 lets all these
      # same-host relays be used together in a single circuit.
      commonTesting = ''
        echo "TestingTorNetwork 1"
        echo "DirAllowPrivateAddresses 1"
        echo "ExitPolicyRejectPrivate 0"
        echo "EnforceDistinctSubnets 0"
        # Skip ORPort reachability self-test: a fresh test network has no Guard
        # relays yet, so no node can build the self-test circuit — without this
        # the relays never get voted Running and the consensus has 0% guard bw.
        echo "AssumeReachable 1"
      '';
      authoritiesOrPlaceholder = ''
        if [ -s /var/lib/tor-da/dirservers.conf ]; then
          cat /var/lib/tor-da/dirservers.conf
        else
          echo '${torPlaceholder}'
        fi
      '';
      # Resolve THIS node's VLAN IP (192.168.x.x). Must match the address other
      # nodes use (getent ahostsv4 das) — NOT eth0's QEMU user-NAT 10.0.2.15,
      # which is what `scope global | head` would pick. Retry: the VLAN IP is not
      # assigned the instant preStart runs.
      myip = ''
        MYIP=""
        for _ in $(seq 1 60); do
          MYIP=$(${pkgs.iproute2}/bin/ip -4 -o addr show \
            | grep -oE '192[.]168[.][0-9]+[.][0-9]+' | head -n1)
          [ -n "$MYIP" ] && break
          sleep 1
        done
      '';

      # One-shot keygen for ALL authorities, run once sequentially at boot. Doing
      # tor-gencert (crypto) in six parallel service preStarts starved the VM and
      # made backdoor.service's serial device time out, so it lives here instead.
      keygenScript = ''
        ${myip}
        for i in 0 1 2; do
          D=/var/lib/tor-da/$i
          mkdir -p $D/keys
          if [ ! -f $D/keys/authority_certificate ]; then
            echo "" | ${gencert} --create-identity-key \
              -i $D/keys/authority_identity_key \
              -s $D/keys/authority_signing_key \
              -c $D/keys/authority_certificate \
              -m 12 -a "$MYIP:$((7000 + i))" --passphrase-fd 0
          fi
          if [ ! -f $D/fingerprint ]; then
            {
              echo "DataDirectory $D"
              echo "DirPort 0.0.0.0:$((7000 + i))"
              echo "ORPort 0.0.0.0:$((5000 + i))"
              echo "Address $MYIP"
              echo "Nickname da$i"
              echo "AuthoritativeDirectory 1"
              echo "V3AuthoritativeDirectory 1"
              echo "TestingTorNetwork 1"
              echo "DirAllowPrivateAddresses 1"
              echo "SocksPort 0"
              echo '${torPlaceholder}'
            } > $D/fpgen-torrc
            ${torBin} --list-fingerprint -f $D/fpgen-torrc || true
          fi
        done
      '';

      # The tor-da/tor-relay services only start once the testScript has written
      # /var/lib/tor-da/dirservers.conf (phase 2) — ConditionPathExists keeps them
      # from restart-looping (and pinning the CPU) during the boot window.
      mkAuthority = i: lib.nameValuePair "tor-da-${toString i}" {
        description = "Tor directory authority ${toString i}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "tor-da-keygen.service" ];
        wants = [ "tor-da-keygen.service" ];
        unitConfig.ConditionPathExists = "/var/lib/tor-da/dirservers.conf";
        serviceConfig = { Type = "simple"; Restart = "on-failure"; RestartSec = "3"; User = "root"; };
        preStart = ''
          ${myip}
          D=/var/lib/tor-da/${toString i}
          {
            echo "DataDirectory $D"
            echo "DirPort 0.0.0.0:${toString (7000 + i)}"
            echo "ORPort 0.0.0.0:${toString (5000 + i)}"
            echo "Address $MYIP"
            echo "Nickname da${toString i}"
            echo "AuthoritativeDirectory 1"
            echo "V3AuthoritativeDirectory 1"
            ${commonTesting}
            # Vote Guard/Exit/HSDir for every relay so onion circuits can be
            # built immediately (bypasses the familiarity/uptime requirements).
            echo "TestingDirAuthVoteGuard *"
            echo "TestingDirAuthVoteExit *"
            echo "TestingDirAuthVoteHSDir *"
            echo "V3AuthVotingInterval 20"
            echo "V3AuthVoteDelay 4"
            echo "V3AuthDistDelay 4"
            echo "TestingV3AuthInitialVotingInterval 20"
            echo "TestingV3AuthInitialVoteDelay 4"
            echo "TestingV3AuthInitialDistDelay 4"
            echo "TestingV3AuthVotingStartOffset 0"
            echo "TestingMinExitFlagThreshold 0"
            echo "MinUptimeHidServDirectoryV2 0"
            echo "SocksPort 0"
            cat /var/lib/tor-da/dirservers.conf
          } > $D/torrc
        '';
        script = "${torBin} -f /var/lib/tor-da/${toString i}/torrc";
      };

      mkRelay = r: lib.nameValuePair "tor-relay-${toString r}" {
        description = "Tor relay ${toString r}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "tor-da-keygen.service" ];
        unitConfig.ConditionPathExists = "/var/lib/tor-da/dirservers.conf";
        serviceConfig = { Type = "simple"; Restart = "on-failure"; RestartSec = "3"; User = "root"; };
        preStart = ''
          ${myip}
          D=/var/lib/tor-da/relay${toString r}
          mkdir -p $D
          {
            echo "DataDirectory $D"
            echo "ORPort 0.0.0.0:${toString (5010 + r)}"
            echo "Address $MYIP"
            echo "Nickname relay${toString r}"
            echo "SocksPort 0"
            ${commonTesting}
            cat /var/lib/tor-da/dirservers.conf
          } > $D/torrc
        '';
        script = "${torBin} -f /var/lib/tor-da/relay${toString r}/torrc";
      };
    in
    {
      # Extra CPU/RAM: this node runs six Tor instances plus key generation.
      virtualisation.cores = 4;
      virtualisation.memorySize = 2048;

      environment.systemPackages = [ pkgs.tor pkgs.iproute2 ];

      networking.firewall = {
        enable = true;
        # authority ORPorts (5000-5002) + DirPorts (7000-7002) + relay ORPorts (5010-5012)
        allowedTCPPorts =
          (lib.range 5000 5002) ++ (lib.range 5010 5012) ++ (lib.range 7000 7002);
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/tor-da 0700 root root -"
      ];

      # Phase 1 (boot): tor-da-keygen generates all authority certs + relay
      # fingerprints; the authority/relay services stay dormant (their
      # ConditionPathExists is unmet). Phase 2: the testScript writes
      # dirservers.conf and starts them, and a consensus forms.
      systemd.services = lib.listToAttrs (
        [ (lib.nameValuePair "tor-da-keygen" {
            description = "Generate Tor directory-authority keys and fingerprints";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" "systemd-tmpfiles-setup.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              TimeoutStartSec = "600";
              User = "root";
            };
            script = keygenScript;
          }) ]
        ++ (lib.map mkAuthority [ 0 1 2 ])
        ++ (lib.map mkRelay [ 0 1 2 ])
      );
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
      # Heavy node: SelfPrivacy API + huey worker + nginx + redis + Tor HS.
      # With the default single vCPU, userspace boot took >5 min and the serial
      # console device (hvc0) timed out, failing backdoor.service.
      virtualisation.cores = 4;
      virtualisation.memorySize = 3072;

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
            echo "TestingTorNetwork 1"
            echo "DirAllowPrivateAddresses 1"
            echo "ExitPolicyRejectPrivate 0"
            echo "EnforceDistinctSubnets 0"
            # Real DirAuthority lines once injected, else the phase-1 placeholder.
            if [ -s /var/lib/tor/dirservers.conf ]; then
              cat /var/lib/tor/dirservers.conf
            else
              echo '${torPlaceholder}'
            fi
          } > /var/lib/tor/torrc
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
          # World-readable so the nginx user can load it (throwaway test cert).
          chmod 644 "$CERT_DIR/key.pem"
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
            # FlakeServiceManager (current API) reads /etc/nixos/flake.nix via `nix eval`.
            # Without sp-module- prefixed inputs, is_installed() returns false for all
            # templated services and the allServices URL assertions in T2.4 fail.
            if [ ! -f /etc/nixos/flake.nix ]; then
              cat > /etc/nixos/flake.nix << 'EOFLAKE'
{
  description = "SelfPrivacy NixOS configuration";
  inputs = {
    selfprivacy-nixos-config = { url = "git+https://git.selfprivacy.org/SelfPrivacy/selfprivacy-nixos-config.git?ref=flakes"; };
    sp-module-nextcloud = { url = "git+https://git.selfprivacy.org/SelfPrivacy/selfprivacy-nixos-config.git?ref=flakes&dir=sp-modules/nextcloud"; };
    sp-module-gitea = { url = "git+https://git.selfprivacy.org/SelfPrivacy/selfprivacy-nixos-config.git?ref=flakes&dir=sp-modules/gitea"; };
    sp-module-matrix = { url = "git+https://git.selfprivacy.org/SelfPrivacy/selfprivacy-nixos-config.git?ref=flakes&dir=sp-modules/matrix"; };
  };
  outputs = _: {};
}
EOFLAKE
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
      virtualisation.cores = 2;
      virtualisation.memorySize = 1536;

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
            echo "TestingTorNetwork 1"
            echo "DirAllowPrivateAddresses 1"
            echo "ExitPolicyRejectPrivate 0"
            echo "EnforceDistinctSubnets 0"
            # Real DirAuthority lines once injected, else the phase-1 placeholder.
            if [ -s /var/lib/tor-client/dirservers.conf ]; then
              cat /var/lib/tor-client/dirservers.conf
            else
              echo '${torPlaceholder}'
            fi
          } > /var/lib/tor-client/torrc
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
    # Each authority's preStart runs tor-gencert (→ authority_certificate) and
    # tor --list-fingerprint (→ fingerprint) before the main tor starts.
    das.wait_for_unit("network.target")

    for i in range(3):
        das.wait_until_succeeds(
            f"test -f /var/lib/tor-da/{i}/fingerprint", timeout=120
        )
        das.wait_until_succeeds(
            f"test -f /var/lib/tor-da/{i}/keys/authority_certificate", timeout=120
        )

    # ── 2. Build the real DirAuthority block (v3ident + relay fingerprint) ────
    # The test driver has no `.ip_address`. Every node's /etc/hosts maps each
    # machine name to its primary VLAN IP (added by the test framework), so
    # resolve das's IPv4 from the backend's hosts file.
    das_ip = backend.succeed(
        "getent ahostsv4 das | grep -oE '([0-9]+[.]){3}[0-9]+' | head -n1"
    ).strip()

    auth_lines = []
    for i in range(3):
        dir_port = 7000 + i
        or_port = 5000 + i
        # fingerprint file: "da{i} <40-hex relay fingerprint>"
        relay_fp = das.succeed(f"cat /var/lib/tor-da/{i}/fingerprint").split()[1]
        # authority_certificate has a line "fingerprint <40-hex v3 identity>"
        v3ident = das.succeed(
            f"grep '^fingerprint' /var/lib/tor-da/{i}/keys/authority_certificate | head -n1"
        ).split()[1]
        auth_lines.append(
            f"DirAuthority da{i} orport={or_port} no-v2 "
            f"v3ident={v3ident} {das_ip}:{dir_port} {relay_fp}"
        )

    dirservers_b64 = base64.b64encode("\n".join(auth_lines).encode()).decode()

    # ── 3. Inject the DirAuthority lines everywhere and restart all Tor nodes ─
    # das keeps one shared dirservers.conf read by all its authorities+relays.
    das.succeed(
        f"echo '{dirservers_b64}' | base64 --decode > /var/lib/tor-da/dirservers.conf"
    )
    for i in range(3):
        das.succeed(f"systemctl restart tor-da-{i}")
        das.wait_for_unit(f"tor-da-{i}")
    for r in range(3):
        das.succeed(f"systemctl restart tor-relay-{r}")
        das.wait_for_unit(f"tor-relay-{r}")

    backend.succeed(
        f"echo '{dirservers_b64}' | base64 --decode > /var/lib/tor/dirservers.conf"
    )
    backend.succeed("systemctl restart selfprivacy-tor")

    client.succeed(
        f"echo '{dirservers_b64}' | base64 --decode > /var/lib/tor-client/dirservers.conf"
    )
    client.succeed("systemctl restart selfprivacy-tor-client")

    # ── 4. Wait for a consensus listing all six relays as Running ─────────────
    das.wait_until_succeeds(
        "test \"$(grep -E '^s .*Running' /var/lib/tor-da/0/cached-consensus "
        "2>/dev/null | wc -l)\" -ge 6",
        timeout=300,
    )

    # ── 5. Read the onion hostname (HS generates it at first boot) ───────────
    backend.wait_until_succeeds(
        "test -f /var/lib/tor/hidden_service/hostname",
        timeout=120,
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
    # Use jq (not an inline python heredoc) so the testScript has no column-0
    # lines, which would defeat Nix indented-string dedenting and corrupt it.
    backend.succeed(
        f"jq '.domain = \"{onion}\"' /etc/nixos/userdata.json > /tmp/ud.json "
        f"&& mv /tmp/ud.json /etc/nixos/userdata.json"
    )
    backend.succeed("systemctl restart selfprivacy-api")
    backend.wait_for_unit("selfprivacy-api.service")
    # The API imports the full strawberry/fastapi app before binding — slow.
    backend.wait_for_open_port(5050, timeout=180)

    # ── 7. Share TLS cert with client (Python HTTP, backend port 8080) ───────
    # Run as a transient unit: a plain "… &" hangs machine.succeed() because the
    # backgrounded server inherits the command channel's stdout (never sees EOF).
    backend.succeed(
        "systemd-run --unit=certserver --collect -- "
        "python3 -m http.server 8080 --directory /etc/ssl/selfprivacy"
    )
    backend.wait_for_open_port(8080, timeout=30)
    # Reach the backend by hostname — the test framework adds it to /etc/hosts.
    client.succeed(
        "curl -sf http://backend:8080/cert.pem -o /tmp/backend-cert.pem"
    )

    # ── 8. Wait for Tor circuit to the hidden service ───────���─────────────────
    TOKEN = "test-token-chutney"
    SOCKS = "--socks5-hostname localhost:9050"
    CACERT = "--cacert /tmp/backend-cert.pem"
    URL = f"https://{onion}"

    # A minimal Tor network is slow to publish/fetch the HS descriptor and to
    # build intro/rendezvous circuits, so allow generous time here.
    client.wait_until_succeeds(
        f"curl {SOCKS} {CACERT} -sf {URL}/api/version",
        timeout=480,
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

    # ── T2.3: Wrong token is rejected on an authenticated field ──────────────
    # api.version is PUBLIC and this GraphQL API returns HTTP 200 with an
    # `errors` body (not 401/403) on auth failure, so probe the authenticated
    # `system` field and inspect the JSON instead of the status code.
    wrong_json = client.succeed(
        f"curl {SOCKS} {CACERT} -s -X POST {URL}/graphql"
        f" -H 'Authorization: Bearer WRONG'"
        f" -H 'Content-Type: application/json'"
        f" -d '{{\"query\": \"{{ system {{ __typename }} }}\"}}'",
    )
    wrong_data = json.loads(wrong_json)
    assert "errors" in wrong_data and (
        wrong_data.get("data") is None or wrong_data["data"].get("system") is None
    ), f"T2.3 failed: wrong token not rejected: {wrong_json}"

    # A valid token DOES grant access to the same authenticated field.
    right_json = client.succeed(
        f"curl {SOCKS} {CACERT} -sf -X POST {URL}/graphql"
        f" -H 'Authorization: Bearer {TOKEN}'"
        f" -H 'Content-Type: application/json'"
        f" -d '{{\"query\": \"{{ system {{ __typename }} }}\"}}'",
    )
    right_data = json.loads(right_json)
    assert right_data.get("data", {}).get("system") is not None, (
        f"T2.3 failed: valid token rejected: {right_json}"
    )

    # ── T2.4: allServices URLs are path-based (not subdomain) for .onion ─────
    services_result = client.succeed(
        f"curl {SOCKS} {CACERT} -sf -X POST {URL}/graphql"
        f" -H 'Authorization: Bearer {TOKEN}'"
        f" -H 'Content-Type: application/json'"
        f" -d '{{\"query\": \"{{ services {{ allServices {{ id url }} }} }}\"}}'",
    )
    services_data = json.loads(services_result)
    services = {
        s["id"]: s["url"]
        for s in services_data["data"]["services"]["allServices"]
        if s.get("url")
    }

    expected = {
        "nextcloud":      f"{URL}/nextcloud/",
        "gitea":          f"{URL}/git/",
        "matrix":         f"{URL}/_matrix/",
        "monitoring":     f"{URL}/prometheus/",
        "selfprivacy-api": f"{URL}/api/",
    }
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
    ROUTED = {"200", "301", "302", "401", "403", "502"}
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
