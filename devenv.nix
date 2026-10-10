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
  cfCli = pkgs.stdenvNoCC.mkDerivation {
    pname = "cf";
    version = "0.10.0";
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/cf/-/cf-0.10.0.tgz";
      hash = "sha512-BC2i2QX2dfV3kxGrwGoELXAGTBBAthccYpergxkgiVkPxGVwFdnkldXei3JcXiAQDN5c+yqibOFwbV7MMlHXeQ==";
    };
    nativeBuildInputs = [ pkgs.makeWrapper ];
    installPhase = ''
      mkdir -p $out/lib/cf $out/bin
      cp -r bin dist package.json $out/lib/cf/
      makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/cf --add-flags $out/lib/cf/bin/cf
    '';
  };
  edgeTask = pkgs.writeShellApplication {
    name = "edge-task";
    excludeShellChecks = [ "SC2016" ];
    runtimeInputs = [ cfCli pkgs.coreutils pkgs.curl pkgs.jq pkgs.findutils pkgs.gnugrep ];
    text = builtins.readFile ./scripts/edge-task.sh;
  };
  sandbox = pkgs.buildEnv {
    name = "nix-cf-proof-sandbox";
    paths = [ patchedGit forcePushProbe gitIdentity cfCli edgeTask pkgs.bashInteractive pkgs.coreutils pkgs.cacert ];
  };
  nixosSystem = import ./nix/nixos-container.nix { inherit pkgs patchedGit; };
  bootProbe = pkgs.writeShellScript "boot-probe" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.busybox}/bin
    mkdir -p /tmp/boot
    {
      echo "pid=$$"
      echo "uid=$(id -u)"
      echo "kernel=$(uname -r)"
      echo "cgroup:"
      cat /proc/self/cgroup
      echo "mounts:"
      cat /proc/self/mounts
      echo "capabilities:"
      grep Cap /proc/self/status
    } > /tmp/boot/preflight.txt 2>&1
    (while true; do
      {
        printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n'
        echo "hostname=$(cat /proc/sys/kernel/hostname)"
        echo "os_release=$(grep -E '^(ID|PRETTY_NAME)=' /etc/os-release 2>/dev/null | tr '\n' ' ')"
        cat /tmp/boot/preflight.txt
        echo '--- systemd console ---'
        tail -c 8000 /tmp/boot/console.log 2>/dev/null
        echo '--- processes ---'
        for p in /proc/[0-9]*; do printf '%s %s\n' "''${p#/proc/}" "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-160)"; done
        echo '--- systemctl ---'
        ${nixosSystem}/sw/bin/systemctl is-system-running 2>&1
        ${nixosSystem}/sw/bin/systemctl list-units --no-pager --state=failed 2>&1 | head -40
        echo '--- journal ---'
        ${nixosSystem}/sw/bin/journalctl -b --no-pager -n 60 2>&1
      } | nc -l -p 8080 >/dev/null 2>&1
    done) &
    {
      echo "init target: $(readlink -f ${nixosSystem}/init)"
      head -c 300 ${nixosSystem}/init
      echo
      echo "before exec $(date -u +%T)"
    } >> /tmp/boot/preflight.txt 2>&1
    exec ${nixosSystem}/init systemd.log_target=console systemd.log_level=info > /tmp/boot/console.log 2>&1
    echo "exec returned $?" >> /tmp/boot/preflight.txt
  '';
  image = pkgs.dockerTools.buildImage {
    name = "nix-cf-proof";
    tag = "latest";
    copyToRoot = [ sandbox ];
    extraCommands = ''
      mkdir -p tmp proof
      chmod 1777 tmp
      ln -s ${sandbox} sandbox
      ln -s ${nixosSystem} nixos-system
      ln -s ${nixosSystem}/init init
      ln -s ${bootProbe} boot-probe
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

  packages = [ patchedGit forcePushProbe gitIdentity cfCli edgeTask ];

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
