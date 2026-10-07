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
grep -q '^FORCE_PUSH_REFUSED=4$' receipts/local-force-push.txt || fail "local git allowed a force push"

call() { curl -fsS --max-time 180 -H "authorization: Bearer $token" "$WORKER_URL$1"; }
call /probe/sandbox > receipts/container-sandbox.json || fail "sandbox probe request failed"
call /probe/systemd > receipts/container-systemd.json || fail "systemd probe request failed"

sandbox=receipts/container-sandbox.json
build_receipt=$(jq -r '.receipt.stdout' "$sandbox")
echo "$build_receipt" > receipts/cloudflare-build.json
jq -e '.workers_ci == "1" and (.workers_ci_build_uuid | length) > 0' receipts/cloudflare-build.json >/dev/null \
  || fail "image was not built by Workers Builds"

container_identity=$(jq -r '.identity.stdout' "$sandbox")
jq -e '.identity.exitCode == 0' "$sandbox" >/dev/null || fail "container git is not the devenv git"
echo "$container_identity" > receipts/container-identity.json

local_version=$(jq -r .version receipts/local-identity.json)
local_patch=$(jq -r .patch_sha256 receipts/local-identity.json)
container_version=$(jq -r .version receipts/container-identity.json)
container_patch=$(jq -r .patch_sha256 receipts/container-identity.json)
container_store=$(jq -r .store_path receipts/container-identity.json)
built_store=$(jq -r .git_store_path receipts/cloudflare-build.json)

[ "$local_version" = "$container_version" ] || fail "git version drift: $local_version vs $container_version"
[ "$local_patch" = "$container_patch" ] || fail "overlay patch drift: $local_patch vs $container_patch"
[ "$container_store" = "$built_store" ] || fail "container git $container_store is not the Cloudflare build output $built_store"

jq -e '.forcePush.exitCode == 0' "$sandbox" >/dev/null || fail "container force-push probe errored"
jq -r '.forcePush.stdout' "$sandbox" | grep -q '^FORCE_PUSH_REFUSED=4$' || fail "container git allowed a force push"

systemd=receipts/container-systemd.json
lifecycle=$(jq -r '.lifecycle // empty' "$systemd")
[ -n "$lifecycle" ] || fail "systemd result not recorded"
if [ "$lifecycle" = "alive-after-20s" ] && jq -e '.pid1.stdout | startswith("systemd")' "$systemd" >/dev/null; then
  systemd_result="boots"
else
  systemd_result="does-not-boot"
fi

jq -n \
  --arg local_version "$local_version" \
  --arg patch "$local_patch" \
  --arg store "$container_store" \
  --arg build_uuid "$(jq -r .workers_ci_build_uuid receipts/cloudflare-build.json)" \
  --arg systemd "$systemd_result" \
  --arg lifecycle "$lifecycle" \
  '{gate: "pass", git_version: $local_version, overlay_patch_sha256: $patch, container_git_store_path: $store, workers_build_uuid: $build_uuid, systemd_entrypoint: $systemd, systemd_lifecycle: $lifecycle}' \
  | tee receipts/gate.json
