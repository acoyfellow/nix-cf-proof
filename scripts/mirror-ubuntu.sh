set -euo pipefail

: "${REGISTRY_PASSWORD:?}"
: "${ACCOUNT_ID:?}"

ubuntu_index_digest=sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

export HOME=/work/home
mkdir -p "$HOME"
export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
export SSL_CERT_FILE=$NIX_SSL_CERT_FILE
export NIX_CONFIG='experimental-features = nix-command flakes
sandbox = false
build-users-group =
filter-syscalls = false'

step() { echo "STEP $(date -u +%FT%TZ) $*"; }

nixpkgs_rev=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync("/work/src/devenv.lock","utf8")).nodes.nixpkgs.locked.rev)')

step skopeo
skopeo_out=$(nix build --no-link --print-out-paths "github:cachix/devenv-nixpkgs/$nixpkgs_rev#skopeo.out")

step push
"$skopeo_out/bin/skopeo" copy --insecure-policy \
  --override-os linux --override-arch amd64 \
  --dest-creds "v1:$REGISTRY_PASSWORD" \
  --digestfile /work/digest \
  "docker://docker.io/library/ubuntu@$ubuntu_index_digest" \
  "docker://registry.cloudflare.com/$ACCOUNT_ID/vm-ubuntu:24.04"

step receipt
UNAME="$(uname -a)" SOURCE_DIGEST="$ubuntu_index_digest" node -e '
const fs = require("fs");
const environ = fs.readFileSync("/proc/1/environ", "utf8").split("\0").filter((line) => line.startsWith("CLOUDFLARE_"));
const receipt = {
  source_image: `docker.io/library/ubuntu@${process.env.SOURCE_DIGEST}`,
  image_digest: fs.readFileSync("/work/digest", "utf8").trim(),
  image_repository: `registry.cloudflare.com/${process.env.ACCOUNT_ID}/vm-ubuntu`,
  uname: process.env.UNAME,
  cloudflare_container_env: Object.fromEntries(environ.map((line) => line.split(/=(.*)/s).slice(0, 2))),
  finished_at: new Date().toISOString(),
};
fs.writeFileSync("/work/receipt.json", JSON.stringify(receipt));
console.log(JSON.stringify(receipt));
'
step done
