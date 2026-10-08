#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

WORKER_URL="${WORKER_URL:-https://nix-cf-proof.coy.workers.dev}"
TOKEN_FILE="receipts/proof-token"
mkdir -p receipts

fail() { echo "GATE FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || fail "missing $1"; }
need devenv
need jq
need curl
test -s "$TOKEN_FILE" || fail "missing $TOKEN_FILE"
token=$(cat "$TOKEN_FILE")

devenv shell -- git-identity > receipts/local-identity.json
devenv shell -- force-push-probe > receipts/local-force-push.txt || fail "local force-push probe failed"
grep -q '^FORCE_PUSH_REFUSED=6$' receipts/local-force-push.txt || fail "local git allowed a force push"

call() { curl -fsS --max-time 180 -H "authorization: Bearer $token" "$WORKER_URL$1"; }
call /probe/sandbox > receipts/container-sandbox.json || fail "sandbox probe request failed"
call /probe/systemd > receipts/container-systemd.json || fail "systemd probe request failed"

sandbox=receipts/container-sandbox.json
test -s receipts/cloudflare-build.json || fail "missing Cloudflare builder receipt"
jq -e '(.cloudflare_container_env.CLOUDFLARE_DURABLE_OBJECT_ID | length) > 0 and (.uname | contains("cloudflare-microvm"))' \
  receipts/cloudflare-build.json >/dev/null || fail "image was not built in a Cloudflare Container"
deployed_image=$(grep -o 'registry.cloudflare.com/[^"]*@sha256:[a-f0-9]*' wrangler.jsonc)
built_image="$(jq -r '.image_repository + "@" + .image_digest' receipts/cloudflare-build.json)"
[ "$deployed_image" = "$built_image" ] || fail "deployed image $deployed_image is not the Cloudflare build $built_image"
image_git=$(jq -r '.receipt.stdout | fromjson | .git_store_path' "$sandbox")

container_identity=$(jq -r '.identity.stdout' "$sandbox")
jq -e '.identity.exitCode == 0' "$sandbox" >/dev/null || fail "container git is not the devenv git"
echo "$container_identity" > receipts/container-identity.json

local_version=$(jq -r .version receipts/local-identity.json)
local_patch=$(jq -r .patch_sha256 receipts/local-identity.json)
container_version=$(jq -r .version receipts/container-identity.json)
container_patch=$(jq -r .patch_sha256 receipts/container-identity.json)
container_store=$(jq -r .store_path receipts/container-identity.json)
built_store=$(jq -r .git_store_path receipts/cloudflare-build.json)
[ "$image_git" = "$built_store" ] || fail "image metadata git $image_git is not the Cloudflare build output $built_store"

[ "$local_version" = "$container_version" ] || fail "git version drift: $local_version vs $container_version"
[ "$local_patch" = "$container_patch" ] || fail "overlay patch drift: $local_patch vs $container_patch"
[ "$container_store" = "$built_store" ] || fail "container git $container_store is not the Cloudflare build output $built_store"

jq -e '.forcePush.exitCode == 0' "$sandbox" >/dev/null || fail "container force-push probe errored"
jq -r '.forcePush.stdout' "$sandbox" | grep -q '^FORCE_PUSH_REFUSED=6$' || fail "container git allowed a force push"

systemd=receipts/container-systemd.json
lifecycle=$(jq -r '.lifecycle // empty' "$systemd")
[ -n "$lifecycle" ] || fail "systemd result not recorded"
jq -e '(.console | length) > 0' "$systemd" >/dev/null || fail "systemd log not recorded"
if jq -e '.console | test("(?m)^1 [^\\n]*systemd")' "$systemd" >/dev/null && ! jq -e '.console | contains("not been booted with systemd")' "$systemd" >/dev/null; then
  systemd_result="boots"
else
  systemd_result="does-not-boot"
fi

jq -n \
  --arg local_version "$local_version" \
  --arg patch "$local_patch" \
  --arg store "$container_store" \
  --arg build_location "$(jq -r '.cloudflare_container_env.CLOUDFLARE_LOCATION' receipts/cloudflare-build.json)" \
  --arg image "$built_image" \
  --arg systemd "$systemd_result" \
  --arg lifecycle "$lifecycle" \
  '{gate: "pass", git_version: $local_version, overlay_patch_sha256: $patch, container_git_store_path: $store, cloudflare_build_location: $build_location, image: $image, systemd_entrypoint: $systemd, systemd_lifecycle: $lifecycle}' \
  | tee receipts/gate.json
