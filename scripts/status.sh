#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
pattern="${1:-.}"
curl -fsS -H "authorization: Bearer $(cat receipts/proof-token)" "${WORKER_URL:-https://nix-cf-proof.coy.workers.dev}/build/status" \
  | PATTERN="$pattern" node -e '
let text = "";
process.stdin.on("data", (chunk) => (text += chunk)).on("end", () => {
  const status = JSON.parse(text);
  const pattern = new RegExp(process.env.PATTERN, "i");
  const log = (status.log || status.lastLog).replace(/\x1b\[[0-9;]*m/g, "");
  console.log(`running=${status.running} exit=${status.exit}`);
  console.log(log.split("\n").filter((line) => pattern.test(line)).slice(-40).join("\n"));
});'
