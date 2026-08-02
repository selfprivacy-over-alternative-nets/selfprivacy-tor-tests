# Level 2: SelfPrivacy HTTPS integration test
#
# Verifies that the selfprivacy-api correctly uses subdomain-based URL routing
# for regular (non-.onion) domains, and that nginx routes subdomains to the
# right backends.
#
# Test IDs: T3.1–T3.8
#
# Node topology:
#   backend  — selfprivacy-api + nginx + self-signed TLS cert (domain: sp-test.example.com)
#
# No Tor, no external DNS — /etc/hosts entries resolve subdomains to 127.0.0.1.

{ pkgs, selfprivacy-api, manager, ... }:

let
  system = "x86_64-linux";

  httpsModule = import "${manager}/backend/nixos/selfprivacy-https-core.nix";

  testDomain = "sp-test.example.com";
  testToken  = "test-token-for-https-development";

  subdomains = [ "api" "cloud" "git" "matrix" "meet" ];
in
{
  name = "selfprivacy-https-integration";

  nodes.backend =
    { config, pkgs, lib, ... }:
    {
      imports = [ httpsModule ];

      _module.args.selfprivacy-api-package = selfprivacy-api.packages.${system}.default;
      _module.args.selfprivacy-domain = testDomain;

      # Resolve domain + all subdomains to localhost (no external DNS needed).
      networking.hosts = {
        "127.0.0.1" =
          [ testDomain ] ++ map (s: "${s}.${testDomain}") subdomains;
      };

      # ── Runtime files required by selfprivacy-api ────────────────────────
      # userdata.json must be a real writable file (WriteUserData opens r+).
      # secrets.json is read-only via environment.etc (ReadUserData opens r).
      # flake.nix stub so FlakeServiceManager's `nix eval` succeeds.
      # sp-modules/ stubs so allServices has metadata for each service.
      system.activationScripts.selfprivacy-test-setup = {
        text = ''
          mkdir -p /etc/nixos /etc/selfprivacy /etc/sp-modules

          [ -f /etc/nixos/userdata.json ] || cat > /etc/nixos/userdata.json <<'EOJSON'
          ${builtins.toJSON {
            username       = "admin";
            hashedPassword = "";
            sshKeys        = [];
            dns            = { provider = "NONE"; };
            server         = { provider = "NONE"; };
            domain         = testDomain;
            autoUpgrade    = { enable = false; };
            timezone       = "UTC";
            modules = {
              nextcloud     = { enable = true; };
              gitea         = { enable = true; };
              "jitsi-meet"  = { enable = true; };
              monitoring    = { enable = true; };
              matrix        = { enable = true; };
            };
          }}
          EOJSON
          chmod 600 /etc/nixos/userdata.json

          # Minimal flake.nix stub so FlakeServiceManager can evaluate it
          [ -f /etc/nixos/flake.nix ] || echo \
            '{ description = "test"; inputs = {}; outputs = _: {}; }' \
            > /etc/nixos/flake.nix

          # Service metadata stubs (sp-module schema v1)
          for svc in nextcloud gitea jitsi-meet matrix monitoring; do
            [ -f /etc/sp-modules/$svc ] || echo \
              "{\"meta\":{\"spModuleSchemaVersion\":1,\"id\":\"$svc\",\"name\":\"$svc\",\"description\":\"$svc\",\"svgIcon\":\"\",\"isMovable\":false,\"isRequired\":false,\"canBeBackedUp\":true,\"backupDescription\":\"\",\"systemdServices\":[\"$svc.service\"],\"folders\":[],\"license\":[],\"homepage\":\"\",\"sourcePage\":\"\",\"supportLevel\":\"normal\"},\"configPathsNeeded\":[],\"options\":{}}" \
              > /etc/sp-modules/$svc
          done
        '';
        deps = [];
      };

      # Read-only API token (migration reads with ReadUserData which tolerates symlinks)
      environment.etc."selfprivacy/secrets.json" = {
        text = builtins.toJSON { api = { token = testToken; }; };
        mode = "0600";
      };

      virtualisation = {
        memorySize = 2048;
        cores = 2;
      };
    };

  testScript = ''
    import json

    backend.start()
    backend.wait_for_unit("selfprivacy-api.service", timeout=120)
    backend.wait_for_open_port(5050, timeout=60)

    # ── T3.1: API responds at https://api.<domain>/api/version ──────────────
    result = backend.succeed(
        "curl -ks https://api.${testDomain}/api/version"
    )
    data = json.loads(result)
    assert "version" in data, f"T3.1 FAIL — expected 'version' key in: {data}"
    print(f"T3.1 PASS: API version = {data['version']}")

    # ── T3.2: Wrong token is rejected ────────────────────────────────────────
    result = backend.succeed(
        "curl -ks "
        "-X POST https://api.${testDomain}/graphql "
        "-H 'Content-Type: application/json' "
        "-H 'Authorization: Bearer wrong-token' "
        "-d '{\"query\":\"{ api { version } }\"}'"
    )
    data = json.loads(result)
    assert "errors" in data, f"T3.2 FAIL — wrong token should produce errors: {data}"
    print("T3.2 PASS: wrong token rejected by GraphQL")

    # ── T3.3: Correct token gives API version ────────────────────────────────
    result = backend.succeed(
        "curl -ks "
        "-X POST https://api.${testDomain}/graphql "
        "-H 'Content-Type: application/json' "
        "-H 'Authorization: Bearer ${testToken}' "
        "-d '{\"query\":\"{ api { version } }\"}'"
    )
    data = json.loads(result)
    assert "data" in data and "errors" not in data, f"T3.3 FAIL: {data}"
    assert data["data"]["api"]["version"], f"T3.3 FAIL — empty version: {data}"
    print(f"T3.3 PASS: GraphQL version = {data['data']['api']['version']}")

    # ── T3.4: allServices returns subdomain URLs (not Tor path URLs) ─────────
    result = backend.succeed(
        "curl -ks "
        "-X POST https://api.${testDomain}/graphql "
        "-H 'Content-Type: application/json' "
        "-H 'Authorization: Bearer ${testToken}' "
        "-d '{\"query\":\"{ services { allServices { id url } } }\"}'"
    )
    data = json.loads(result)
    assert "errors" not in data, f"T3.4 FAIL — GraphQL error: {data}"
    services = data["data"]["services"]["allServices"]

    tor_paths = ["/nextcloud/", "/git/", "/_matrix/", "/prometheus/", "/jitsi/"]
    for svc in services:
        url = svc.get("url")
        if url is None:
            continue
        assert "${testDomain}" in url, (
            f"T3.4 FAIL: {svc['id']} url={url!r} missing domain"
        )
        for path in tor_paths:
            assert path not in url, (
                f"T3.4 FAIL: {svc['id']} url={url!r} uses Tor path-routing"
            )
    print(f"T3.4 PASS: {len(services)} services all use subdomain routing")
    for svc in services:
        if svc.get("url"):
            print(f"  {svc['id']}: {svc['url']}")

    # ── T3.5: selfprivacy-api URL is https://api.<domain> (subdomain form) ───
    # ServiceManager.get_url() returns "https://api.{domain}" for non-.onion domains
    api_svc = next((s for s in services if s["id"] == "selfprivacy-api"), None)
    assert api_svc is not None, "T3.5 FAIL — selfprivacy-api not in allServices"
    expected = "https://api.${testDomain}"
    assert api_svc["url"] == expected, (
        f"T3.5 FAIL: expected {expected!r}, got {api_svc['url']!r}"
    )
    print(f"T3.5 PASS: selfprivacy-api URL = {api_svc['url']}")

    # ── T3.6: nginx routes api.<domain> to the API process ───────────────────
    result = backend.succeed(
        "curl -ks https://api.${testDomain}/api/version"
    )
    data = json.loads(result)
    assert "version" in data, f"T3.6 FAIL — nginx routing broken: {data}"
    print(f"T3.6 PASS: nginx routes api.${testDomain}")

    # ── T3.7: TLS cert covers domain and wildcard subdomain ───────────────────
    cert_text = backend.succeed(
        "openssl x509 -in /etc/ssl/selfprivacy-https/cert.pem -noout -text"
    )
    assert "${testDomain}" in cert_text, (
        f"T3.7 FAIL: cert SAN missing ${testDomain}"
    )
    assert "*.${testDomain}" in cert_text, (
        f"T3.7 FAIL: cert SAN missing *.${testDomain}"
    )
    print("T3.7 PASS: TLS cert covers ${testDomain} and *.${testDomain}")

    # ── T3.8: TLS handshake succeeds for api.<domain> ────────────────────────
    # -k skips CA validation (self-signed cert); we only check the handshake completes
    backend.succeed(
        "curl -ks --max-time 10 https://api.${testDomain}/api/version > /dev/null"
    )
    print("T3.8 PASS: TLS handshake to api.${testDomain}:443 succeeds")

    print("")
    print("===== HTTPS integration tests: ALL PASSED (T3.1–T3.8) =====")
  '';
}
