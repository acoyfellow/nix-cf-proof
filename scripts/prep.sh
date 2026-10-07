#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
token=$(npx wrangler auth token 2>/dev/null | grep -v '^\s*$' | tail -1)
for image in "$@"; do
  curl -fsS -X POST -H "Authorization: Bearer $token" -H 'content-type: application/json' \
    "https://api.cloudflare.com/client/v4/accounts/bfcb6ac5b3ceaf42a09607f6f7925823/containers/image-preparations" \
    -d "{\"image\":\"$image\"}" \
    | IMAGE="$image" node -e 'let t="";process.stdin.on("data",d=>t+=d).on("end",()=>{const r=JSON.parse(t).result;console.log(`${process.env.IMAGE.split("/").pop().slice(0,40)} ${r.status} ${r.reason||""}`)})'
done
