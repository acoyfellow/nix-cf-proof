#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

account_id=bfcb6ac5b3ceaf42a09607f6f7925823
worker=${TASK_WORKER:-terrarium-hello}
goal="Upload the code for a new hello-world Worker named $worker, then turn on its workers.dev URL. Do not touch any other Worker."
task_id="edge-$(date -u +%Y%m%d%H%M%S)"
worker_url=${WORKER_URL:-https://nix-cf-proof.coy.workers.dev}

token_meta=$(TASK_ACCOUNT_ID=$account_id ./scripts/mint-task-token.sh "$task_id" 1800)
token_file=$HOME/.terrarium/secrets/task-tokens/$task_id.secret
api=https://api.cloudflare.com/client/v4/accounts/$account_id
probe() { curl -s -H "Authorization: Bearer $(cat "$token_file")" "$api/$1" | jq -r .success; }
token_probe=$(jq -n --arg r2 "$(probe r2/buckets)" --arg tokens "$(probe tokens)" --arg workers "$(probe workers/scripts)" \
  '{workers_allowed: ($workers == "true"), r2_denied: ($r2 != "true"), tokens_denied: ($tokens != "true")}')

response=$(jq -n --rawfile token "$token_file" --arg worker "$worker" --arg goal "$goal" \
  '{taskToken: ($token | rtrimstr("\n")), worker: $worker, goal: $goal}' |
  curl -fsS --max-time 600 -X POST -H "authorization: Bearer $(cat receipts/proof-token)" -H 'content-type: application/json' \
    --data @- "$worker_url/edge/task")

image=$(grep -o 'registry.cloudflare.com/[^"]*' wrangler.jsonc | head -1)
steps=$(jq -r '.task.stdout' <<< "$response" | sed -n '/EDGE_TASK_RECEIPT_BEGIN/,/EDGE_TASK_RECEIPT_END/p' | sed '1d;$d' | jq -s .)
[ "$(jq length <<< "$steps")" -gt 0 ] || { jq . <<< "$response" >&2; exit 1; }

jq -n \
  --arg image "$image" \
  --arg kernel "$(jq -r '.uname.stdout' <<< "$response" | awk 'NF {print $3; exit}')" \
  --argjson token "$token_meta" \
  --argjson probe "$token_probe" \
  --argjson steps "$steps" \
  --argjson image_receipt "$(jq -r '.receipt.stdout' <<< "$response")" \
  --arg task_stderr "$(jq -r '.task.stderr' <<< "$response" | tail -c 1500)" \
  --arg task_exit "$(jq -r '.task.exitCode' <<< "$response")" \
  '{image: $image, image_receipt: $image_receipt, cell_kernel: $kernel, token: ($token | del(.id)), token_probe: $probe,
    task_exit: ($task_exit | tonumber), task_stderr: $task_stderr, steps: $steps}' > receipts/edge-task.json

rm -f "$token_file"
jq '{cell_kernel, token, token_probe, task_exit, steps: [.steps[] | {step, command: (.command // empty | join(" ")), decision: (.verdict.decision // empty), ran: (.ran // empty), status: (.status // empty), refused: (.refused // empty), credential_files: (.credential_files // empty)}]}' receipts/edge-task.json
