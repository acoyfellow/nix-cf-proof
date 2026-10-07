{ pkgs, patchedGit }:
let
  basePkgs = import pkgs.path { inherit (pkgs.stdenv.hostPlatform) system; };
  system = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    pkgs = basePkgs;
    system = null;
    modules = [
      ({ ... }: {
        boot.isContainer = true;
        nix.enable = false;
        documentation.enable = false;
        networking.hostName = "nix-cf-proof";
        networking.useDHCP = false;
        environment.systemPackages = [ patchedGit ];
        system.stateVersion = "25.05";
      })
    ];
  };
in
system.config.system.build.toplevel
