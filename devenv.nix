{ pkgs, lib, ... }:
let
  patchedGit = pkgs.git;
  forcePushProbe = pkgs.writeShellApplication {
    name = "force-push-probe";
    runtimeInputs = [ patchedGit pkgs.coreutils pkgs.gnugrep ];
    text = builtins.readFile ./scripts/force-push-probe.sh;
  };
  gitIdentity = pkgs.writeShellApplication {
    name = "git-identity";
    runtimeInputs = [ patchedGit pkgs.coreutils ];
    text = ''
      git_bin=$(readlink -f "$(command -v git)")
      printf '{"version":"%s","store_path":"%s","patch_sha256":"%s"}\n' \
        "$(git --version)" "${patchedGit}" \
        "$(cat ${lib.concatStringsSep " " (map toString patchedGit.forcePushPatches)} | sha256sum | cut -d' ' -f1)"
      test "$git_bin" = "${patchedGit}/bin/git"
    '';
  };
in
{
  overlays = [ (import ./nix/overlay.nix) ];

  packages = [ patchedGit forcePushProbe gitIdentity pkgs.bun ];

  outputs = {
    git = patchedGit;
    sandbox = pkgs.buildEnv {
      name = "nix-cf-proof-sandbox";
      paths = [ patchedGit forcePushProbe gitIdentity pkgs.bashInteractive pkgs.coreutils pkgs.cacert ];
    };
  } // lib.optionalAttrs pkgs.stdenv.isLinux {
    nixos = import ./nix/nixos-container.nix { inherit pkgs; };
  };

  enterTest = ''
    git-identity
    force-push-probe
  '';
}
