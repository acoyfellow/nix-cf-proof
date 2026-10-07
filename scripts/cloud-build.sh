#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

WORKER_URL="${WORKER_URL:-https://nix-cf-proof.coy.workers.dev}"
token=$(cat receipts/proof-token)
sha=$(git rev-parse HEAD)
git fetch -q origin main
[ "$(git rev-parse origin/main)" = "$sha" ] || { echo "push HEAD to origin/main first"; exit 1; }

password=$(npx wrangler containers registries credentials registry.cloudflare.com --push --pull --expiration-minutes 90 --json \
  | node -e 'let t="";process.stdin.on("data",d=>t+=d).on("end",()=>process.stdout.write(JSON.parse(t.slice(t.indexOf("{"))).password))')

node -e 'process.stdout.write(JSON.stringify({sourceSha: process.argv[1], registryPassword: process.argv[2]}))' "$sha" "$password" \
  | curl -fsS -X POST -H "authorization: Bearer $token" -H 'content-type: application/json' --data-binary @- "$WORKER_URL/build/start"
echo
echo "build started for $sha"
