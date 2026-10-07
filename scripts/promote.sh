#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

token=$(cat receipts/proof-token)
worker="${WORKER_URL:-https://nix-cf-proof.coy.workers.dev}"

curl -fsS -H "authorization: Bearer $token" "$worker/build/status" \
  | node -e 'let t="";process.stdin.on("data",d=>t+=d).on("end",()=>{const r=JSON.parse(t).receipt;if(!r)process.exit(1);process.stdout.write(r)})' \
  > receipts/cloudflare-build.json
curl -fsS -X POST -H "authorization: Bearer $token" "$worker/stop" >/dev/null

image=$(node -p 'const r=require("./receipts/cloudflare-build.json");r.image_repository+"@"+r.image_digest')
echo "image $image"
for attempt in $(seq 1 40); do
  result=$(./scripts/prep.sh "$image")
  echo "$result"
  case "$result" in
    *" ready "*) break ;;
    *failed*) echo "image preparation failed"; exit 1 ;;
  esac
  sleep 15
done

IMAGE="$image" node -e '
const fs = require("fs");
const path = "wrangler.jsonc";
const text = fs.readFileSync(path, "utf8");
const next = text.replace(/"image": "registry\.cloudflare\.com\/[^"]+"/, `"image": "${process.env.IMAGE}"`);
if (next === text && !text.includes(process.env.IMAGE)) throw new Error("no sandbox image entry in wrangler.jsonc");
fs.writeFileSync(path, next);
'
GUARDRAIL_WORKERS_SUBDOMAIN=coy npx wrangler deploy 2>&1 | grep -E "ready to run|Current Version|ERROR"
