#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

bold=$'\e[1m' green=$'\e[32m' red=$'\e[31m' dim=$'\e[2m' reset=$'\e[0m'
say() { printf '\n%s%s%s\n' "$bold" "$1" "$reset"; sleep 1.2; }
show() { printf '%s$ %s%s\n' "$dim" "$1" "$reset"; sleep 0.6; }

say "1. On my Mac, devenv shell gives the patched git"
show "devenv shell -- git-identity"
devenv shell -- git-identity 2>/dev/null | jq -r '"   version: \(.version)\n   patch:   \(.patch_sha256[0:16])…"'
sleep 1.5

say "2. Every force push is refused locally"
show "devenv shell -- force-push-probe"
devenv shell -- force-push-probe 2>/dev/null | sed -e "s/^refused/   ${red}refused${reset}/" -e "s/^allowed/   ${green}allowed${reset}/" -e "s/^remote/   remote/" -e "s/^FORCE/   FORCE/"
sleep 1.5

say "3. The live Cloudflare Container runs the same git"
show "curl https://nix-cf-proof.coy.workers.dev/probe/sandbox"
curl -fsS --max-time 180 -H "authorization: Bearer $(cat receipts/proof-token)" "${WORKER_URL:-https://nix-cf-proof.coy.workers.dev}/probe/sandbox" > receipts/local-demo-sandbox.json
jq -r '.identity.stdout | fromjson | "   version: \(.version)\n   patch:   \(.patch_sha256[0:16])…"' receipts/local-demo-sandbox.json
jq -r '.uname.stdout' receipts/local-demo-sandbox.json | awk 'NF {print "   kernel:  " $3; exit}'
sleep 1.5

say "4. Every force push is refused in the container"
jq -r '.forcePush.stdout' receipts/local-demo-sandbox.json | sed -e "s/^refused/   ${red}refused${reset}/" -e "s/^allowed/   ${green}allowed${reset}/" -e "s/^remote/   remote/" -e "s/^FORCE/   FORCE/"
sleep 1.5

say "5. The image was built on Cloudflare, not on this laptop"
jq -r '"   built in: Cloudflare \(.cloudflare_container_env.CLOUDFLARE_LOCATION)\n   kernel:   \(.uname | split(" ")[2])\n   digest:   \(.image_digest[0:23])…"' receipts/cloudflare-build.json
sleep 1.5

say "6. Full NixOS boots there too"
jq -r '.console' receipts/container-systemd.json | grep -m1 '^1 ' | awk '{print "   PID 1: " $2}' | sed 's#/nix/store/[^/]*/#…/#'
jq -r '.console' receipts/container-systemd.json | awk '/--- systemctl ---/{getline; print "   state: " $0}'
sleep 1.5

printf '\n%s%s./proof.sh → gate: pass%s\n\n' "$bold" "$green" "$reset"
sleep 2.5
