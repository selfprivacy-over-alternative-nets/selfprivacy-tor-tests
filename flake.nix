{
  description = "SelfPrivacy-over-Tor integration and E2E test infrastructure";

  inputs = {
    # Pinned to the SAME nixpkgs the deployed backend builds from
    # (Manager/backend/flake.lock), so the L2 VM boots the same nixpkgs as production instead of
    # drifting on nixos-26.05. Bump this rev whenever the backend's nixpkgs pin changes.
    nixpkgs.url = "github:NixOS/nixpkgs/23d72dabcb3b12469f57b37170fcbc1789bd7457";

    selfprivacy-api = {
      url = "git+https://github.com/selfprivacy-over-alternative-nets/selfprivacy-api.git?ref=tor-support";
    };

    manager = {
      url = "git+https://github.com/selfprivacy-over-alternative-nets/Manager-Ubuntu-SelfPrivacy-Over-alternative-nets.git";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      selfprivacy-api,
      manager,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      checks.${system} = {
        tor-integration = pkgs.testers.runNixOSTest (
          import ./tests/level2/tor-integration.nix {
            inherit pkgs selfprivacy-api manager;
          }
        );

        https-integration = pkgs.testers.runNixOSTest (
          import ./tests/level2/https-integration.nix {
            inherit pkgs selfprivacy-api manager;
          }
        );
      };

      # Interactive drivers for debugging Level 2
      packages.${system} = {
        level2-driver =
          (pkgs.testers.runNixOSTest (
            import ./tests/level2/tor-integration.nix {
              inherit pkgs selfprivacy-api manager;
            }
          )).driverInteractive;

        level2-https-driver =
          (pkgs.testers.runNixOSTest (
            import ./tests/level2/https-integration.nix {
              inherit pkgs selfprivacy-api manager;
            }
          )).driverInteractive;

        # Non-interactive drivers: `nix run` these as the invoking user (who has
        # /dev/kvm access) so QEMU uses KVM, unlike `nix build .#checks.*` whose
        # sandboxed nixbld users cannot open /dev/kvm and fall back to slow TCG.
        level2-https-run =
          (pkgs.testers.runNixOSTest (
            import ./tests/level2/https-integration.nix {
              inherit pkgs selfprivacy-api manager;
            }
          )).driver;

        level2-tor-run =
          (pkgs.testers.runNixOSTest (
            import ./tests/level2/tor-integration.nix {
              inherit pkgs selfprivacy-api manager;
            }
          )).driver;
      };
    };
}
