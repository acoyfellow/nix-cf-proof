set -euo pipefail

: "${REGISTRY_PASSWORD:?}"
: "${ACCOUNT_ID:?}"

export HOME=/work/home
mkdir -p "$HOME"
export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
export NIX_CONFIG='experimental-features = nix-command flakes
sandbox = false
build-users-group =
filter-syscalls = false
max-jobs = auto'

rev=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync("/work/src/devenv.lock","utf8")).nodes.nixpkgs.locked.rev)')
skopeo=$(nix build --no-link --print-out-paths "github:cachix/devenv-nixpkgs/$rev#skopeo.out")/bin/skopeo

variant() {
  local name=$1 expr=$2
  rm -rf /homeless-shelter
  local out
  out=$(nix build --no-link --print-out-paths --impure --expr "
    let pkgs = import (builtins.getFlake \"github:cachix/devenv-nixpkgs/$rev\") { system = \"x86_64-linux\"; };
    in $expr")
  "$skopeo" copy --insecure-policy --dest-creds "v1:$REGISTRY_PASSWORD" --digestfile "/work/digest-$name" \
    "docker-archive:$out" "docker://registry.cloudflare.com/$ACCOUNT_ID/nix-cf-probe-$name:latest"
  echo "PROBE $name registry.cloudflare.com/$ACCOUNT_ID/nix-cf-probe-$name@$(cat /work/digest-$name)"
}

variant single 'pkgs.dockerTools.buildImage { name = "p"; copyToRoot = [ pkgs.busybox ]; config.Cmd = [ "/bin/sleep" "infinity" ]; }'
variant layered 'pkgs.dockerTools.buildLayeredImage { name = "p"; contents = [ pkgs.busybox ]; config.Cmd = [ "/bin/sleep" "infinity" ]; }'
variant rootlinks 'pkgs.dockerTools.buildLayeredImage { name = "p"; contents = [ pkgs.busybox ]; extraCommands = "mkdir -p tmp; chmod 1777 tmp; ln -s ${pkgs.busybox} sandbox; ln -s ${pkgs.busybox}/bin/sh init"; config.Cmd = [ "/bin/sleep" "infinity" ]; }'
variant nocontents 'pkgs.dockerTools.buildLayeredImage { name = "p"; extraCommands = "mkdir -p tmp; chmod 1777 tmp; ln -s ${pkgs.busybox} sandbox"; config.Cmd = [ "${pkgs.busybox}/bin/sleep" "infinity" ]; config.Env = [ "PATH=/sandbox/bin" ]; }'
echo "PROBE done"
