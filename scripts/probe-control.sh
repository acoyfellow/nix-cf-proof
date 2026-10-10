set -euo pipefail

: "${REGISTRY_PASSWORD:?}"
: "${ACCOUNT_ID:?}"

export HOME=/work/home
mkdir -p "$HOME"
export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
export NIX_CONFIG='experimental-features = nix-command flakes
sandbox = false
build-users-group =
filter-syscalls = false'

rev=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync("/work/src/devenv.lock","utf8")).nodes.nixpkgs.locked.rev)')
skopeo=$(nix build --no-link --print-out-paths "github:cachix/devenv-nixpkgs/$rev#skopeo.out")/bin/skopeo

push() {
  local name=$1 source=$2
  shift 2
  "$skopeo" copy --insecure-policy "$@" --dest-creds "v1:$REGISTRY_PASSWORD" --digestfile "/work/digest-$name" \
    "$source" "docker://registry.cloudflare.com/$ACCOUNT_ID/nix-cf-probe-$name:latest"
  echo "PROBE $name registry.cloudflare.com/$ACCOUNT_ID/nix-cf-probe-$name@$(cat /work/digest-$name)"
}

push hub-busybox docker://docker.io/library/busybox:1.37 --override-os linux --override-arch amd64
push hub-busybox-oci docker://docker.io/library/busybox:1.37 --override-os linux --override-arch amd64 --format oci
proof=$(ls -d /nix/store/*-nix-cf-proof.tar.gz 2>/dev/null | head -1 || true)
if [ -n "$proof" ]; then
  push proof-oci "docker-archive:$proof" --format oci
fi
layered=$(nix build --no-link --print-out-paths --impure --expr "
  let pkgs = import (builtins.getFlake \"github:cachix/devenv-nixpkgs/$rev\") { system = \"x86_64-linux\"; };
  in pkgs.dockerTools.buildLayeredImage { name = \"p\"; contents = [ pkgs.busybox ]; config.Cmd = [ \"/bin/sleep\" \"infinity\" ]; }")
push layered-oci "docker-archive:$layered" --format oci
echo "PROBE done"
