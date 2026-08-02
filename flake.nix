{
  description = "SelfPrivacy-over-Tor integration and E2E test infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

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
      };
    };
}
