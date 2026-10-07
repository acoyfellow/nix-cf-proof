{ pkgs }:
let
  system = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    inherit pkgs;
    system = null;
    modules = [
      ({ ... }: {
        boot.isContainer = true;
        networking.hostName = "nix-cf-proof";
        networking.useDHCP = false;
        environment.systemPackages = [ pkgs.git ];
        system.stateVersion = "25.05";
      })
    ];
  };
in
system.config.system.build.toplevel
