{ pkgs, lib, ... }:
let
  patchedGit = pkgs.git;
  patchSha256 = builtins.hashString "sha256"
    (lib.concatMapStrings builtins.readFile patchedGit.forcePushPatches);
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
      test "$git_bin" = "${patchedGit}/bin/git"
      printf '{"version":"%s","store_path":"%s","patch_sha256":"%s"}\n' \
        "$(git --version)" "${patchedGit}" "${patchSha256}"
    '';
  };
  sandbox = pkgs.buildEnv {
    name = "nix-cf-proof-sandbox";
    paths = [ patchedGit forcePushProbe gitIdentity pkgs.bashInteractive pkgs.coreutils pkgs.cacert ];
  };
  nixosSystem = import ./nix/nixos-container.nix { inherit pkgs patchedGit; };
  image = pkgs.dockerTools.buildLayeredImage {
    name = "nix-cf-proof";
    tag = "latest";
    contents = [ sandbox ];
    extraCommands = ''
      mkdir -p tmp proof
      chmod 1777 tmp
      ln -s ${sandbox} sandbox
      ln -s ${nixosSystem} nixos-system
      ln -s ${nixosSystem}/init init
      printf '{"git_store_path":"%s","sandbox_store_path":"%s","nixos_toplevel":"%s"}\n' \
        "${patchedGit}" "${sandbox}" "${nixosSystem}" > proof/image.json
    '';
    config = {
      Cmd = [ "${pkgs.coreutils}/bin/sleep" "infinity" ];
      Env = [
        "PATH=/sandbox/bin"
        "HOME=/tmp"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
    };
  };
in
{
  overlays = [ (import ./nix/overlay.nix) ];

  packages = [ patchedGit forcePushProbe gitIdentity ];

  outputs = {
    git = patchedGit;
    inherit sandbox;
  } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    inherit image;
    nixos = nixosSystem;
  };

  enterTest = ''
    git-identity
    force-push-probe
  '';
}
