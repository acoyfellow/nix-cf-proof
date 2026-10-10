#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "GATE FAIL: $*" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
prefix=proof$(date -u +%H%M%S)

./scripts/vms.sh destroy --all > "$work/pre-destroy.json"
[ "$(grep -o 'nix-cf-proof@sha256:[a-f0-9]*' wrangler.jsonc | sort -u | wc -l | tr -d " ")" = 1 ] || fail "wrangler.jsonc pins more than one nix-cf-proof image"

started=$(date +%s)
VMS_JSON_OUT="$work/create.json" ./scripts/vms.sh create --ubuntu 5 --nixos 5 --prefix "$prefix" > "$work/create.txt"
create_seconds=$(( $(date +%s) - started ))
cat "$work/create.txt"

VMS_JSON_OUT="$work/list.json" ./scripts/vms.sh list > "$work/list.txt"
jq -e '[.vms[] | select(.error)] | length == 0' "$work/create.json" >/dev/null ||
  fail "create errors: $(jq -c '[.vms[] | select(.error) | {name, error}]' "$work/create.json")"

vms=$(jq '[.vms[] | select(.name | startswith("'"$prefix"'-"))]' "$work/list.json")
[ "$(jq length <<< "$vms")" = 10 ] || fail "expected 10 vms, listed $(jq length <<< "$vms")"
jq -e 'all(.running)' <<< "$vms" >/dev/null || fail "not all vms running"
jq -e '[.[].containerId] | (map(select(. != null and length > 8)) | unique | length) == 10' <<< "$vms" >/dev/null ||
  fail "container ids are not 10 distinct values: $(jq -c '[.[].containerId]' <<< "$vms")"
jq -e '[.[] | select(.flavor == "ubuntu" and (.osRelease | test("ID=ubuntu")))] | length == 5' <<< "$vms" >/dev/null ||
  fail "expected 5 Ubuntu os-release: $(jq -c '[.[] | {name, osRelease}]' <<< "$vms")"
jq -e '[.[] | select(.flavor == "nixos" and (.osRelease | test("ID=nixos")))] | length == 5' <<< "$vms" >/dev/null ||
  fail "expected 5 NixOS os-release: $(jq -c '[.[] | {name, osRelease}]' <<< "$vms")"
jq -e '[.[] | select(.flavor == "nixos" and .pid1 == "systemd")] | length == 5' <<< "$vms" >/dev/null ||
  fail "expected systemd PID 1 on 5 NixOS: $(jq -c '[.[] | select(.flavor == "nixos") | {name, pid1}]' <<< "$vms")"
jq -e 'all(.kernel | test("cloudflare-microvm"))' <<< "$vms" >/dev/null ||
  fail "non-Cloudflare kernel: $(jq -c '[.[] | {name, kernel}]' <<< "$vms")"

exec_name="$prefix-ubuntu-3"
exec_out=$(./scripts/vms.sh exec "$exec_name" 'echo hello-from-$(cat /proc/sys/kernel/hostname | cut -c1-12)')
expected_host=$(jq -r --arg n "$exec_name" '.[] | select(.name == $n) | .containerId[0:12]' <<< "$vms")
grep -q "hello-from-$expected_host" <<< "$exec_out" || fail "exec did not reach $exec_name: $exec_out"

./scripts/vms.sh destroy --all > "$work/destroy.json"
sleep 5
VMS_JSON_OUT="$work/after.json" ./scripts/vms.sh list > /dev/null
running_after=$(jq '[.vms[] | select(.running)] | length' "$work/after.json")
[ "$running_after" = 0 ] || fail "$running_after vms still running after destroy"

jq -n \
  --argjson vms "$vms" \
  --arg exec_name "$exec_name" \
  --arg exec_out "$exec_out" \
  --argjson create_seconds "$create_seconds" \
  --argjson running_after "$running_after" \
  --slurpfile destroyed "$work/destroy.json" \
  --slurpfile ubuntu "receipts/ubuntu-mirror.json" \
  --arg nixos_image "$(grep -o 'nix-cf-proof@sha256:[a-f0-9]*' wrangler.jsonc | sort -u | tr '\n' ' ')" \
  '{gate: "pass", create_seconds: $create_seconds,
    images: {ubuntu: $ubuntu[0].image_digest, nixos_deployed: ($nixos_image | rtrimstr(" "))},
    vms: [$vms[] | {name, flavor, containerId, osRelease, kernel, pid1, systemState}],
    exec: {name: $exec_name, output: $exec_out}, destroyed: $destroyed[0].destroyed, running_after_destroy: $running_after}' |
  tee receipts/vms.json
