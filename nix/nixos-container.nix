{ pkgs }:
let
  system = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    system = "x86_64-linux";
    modules = [
      ({ ... }: {
        boot.isContainer = true;
        networking.hostName = "nix-cf-proof";
        networking.useDHCP = false;
        services.getty.autologinUser = null;
        environment.systemPackages = [ pkgs.git ];
        system.stateVersion = "25.11";
      })
    ];
  };
in
system.config.system.build.toplevel
