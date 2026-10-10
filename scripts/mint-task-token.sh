#!/usr/bin/env bash
set -euo pipefail

account_id=${TASK_ACCOUNT_ID:-bfcb6ac5b3ceaf42a09607f6f7925823}
minter_file=${TOKEN_MINTER_FILE:-$HOME/.terrarium/secrets/coy-token-minter.secret}
task_id=${1:?usage: mint-task-token.sh <task-id> [ttl-seconds]}
ttl_seconds=${2:-3600}
out_dir=${TASK_TOKEN_DIR:-$HOME/.terrarium/secrets/task-tokens}

workers_scripts_write=e086da7e2179491d91ee5f35b3ca210a
workers_scripts_read=1a71c399035b4950a1bd1466bbe4f420

expires_on=$(date -u -v+"${ttl_seconds}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+${ttl_seconds} seconds" +%Y-%m-%dT%H:%M:%SZ)
body=$(jq -n \
  --arg name "terrarium-task-$task_id" \
  --arg account "com.cloudflare.api.account.$account_id" \
  --arg write "$workers_scripts_write" \
  --arg read "$workers_scripts_read" \
  --arg expires "$expires_on" \
  '{name: $name, expires_on: $expires, policies: [{effect: "allow", resources: {($account): "*"}, permission_groups: [{id: $write}, {id: $read}]}]}')

response=$(curl -sS -X POST \
  -H "Authorization: Bearer $(cat "$minter_file")" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/accounts/$account_id/tokens" \
  --data "$body")

jq -e .success <<< "$response" >/dev/null || { jq -c .errors <<< "$response" >&2; exit 1; }
mkdir -p "$out_dir"
chmod 700 "$out_dir"
umask 077
jq -r '.result.value' <<< "$response" > "$out_dir/$task_id.secret"
jq '{id: .result.id, name: .result.name, expires_on: .result.expires_on, permission_groups: [.result.policies[].permission_groups[].name], resources: [.result.policies[].resources | keys[]]}' <<< "$response" > "$out_dir/$task_id.json"
cat "$out_dir/$task_id.json"
