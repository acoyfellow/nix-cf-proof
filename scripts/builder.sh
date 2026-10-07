set -euo pipefail

: "${REGISTRY_PASSWORD:?}"
: "${ACCOUNT_ID:?}"
: "${SOURCE_SHA:?}"

export HOME=/work/home
mkdir -p "$HOME"
export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
export SSL_CERT_FILE=$NIX_SSL_CERT_FILE
NIX_CONFIG=$(cat <<'CONF'
experimental-features = nix-command flakes
sandbox = false
build-users-group =
filter-syscalls = false
max-jobs = auto
cores = 0
extra-substituters = https://devenv.cachix.org
extra-trusted-public-keys = devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=
CONF
)
export NIX_CONFIG

step() { echo "STEP $(date -u +%FT%TZ) $*"; }
json_field() { node -e "process.stdout.write(String(require('$1')$2))"; }

nixpkgs_rev=$(json_field /work/src/devenv.lock ".nodes.nixpkgs.locked.rev")

step devenv
devenv_out=$(nix build --no-link --print-out-paths github:cachix/devenv/v2.4.0)
export PATH="$devenv_out/bin:$PATH"
devenv version || true

step build
devenv build outputs.git outputs.image > /work/build.json
cat /work/build.json
git_store_path=$(json_field /work/build.json "['outputs.git']")
image_store_path=$(json_field /work/build.json "['outputs.image']")

step skopeo
skopeo_out=$(nix build --no-link --print-out-paths "github:cachix/devenv-nixpkgs/$nixpkgs_rev#skopeo")

step push
"$skopeo_out/bin/skopeo" copy --insecure-policy \
  --dest-creds "v1:$REGISTRY_PASSWORD" \
  --digestfile /work/digest \
  "docker-archive:$image_store_path" \
  "docker://registry.cloudflare.com/$ACCOUNT_ID/nix-cf-proof:$SOURCE_SHA"

step receipt
GIT_STORE_PATH="$git_store_path" IMAGE_STORE_PATH="$image_store_path" NIXPKGS_REV="$nixpkgs_rev" \
NIX_VERSION="$(nix --version)" UNAME="$(uname -a)" node -e '
const fs = require("fs");
const environ = fs.readFileSync("/proc/1/environ", "utf8").split("\0").filter((line) => line.startsWith("CLOUDFLARE_"));
const receipt = {
  source_sha: process.env.SOURCE_SHA,
  nixpkgs_rev: process.env.NIXPKGS_REV,
  git_store_path: process.env.GIT_STORE_PATH,
  image_store_path: process.env.IMAGE_STORE_PATH,
  image_digest: fs.readFileSync("/work/digest", "utf8").trim(),
  image_repository: `registry.cloudflare.com/${process.env.ACCOUNT_ID}/nix-cf-proof`,
  nix_version: process.env.NIX_VERSION,
  uname: process.env.UNAME,
  cloudflare_container_env: Object.fromEntries(environ.map((line) => line.split(/=(.*)/s).slice(0, 2))),
  finished_at: new Date().toISOString(),
};
fs.writeFileSync("/work/receipt.json", JSON.stringify(receipt));
console.log(JSON.stringify(receipt));
'
step done
