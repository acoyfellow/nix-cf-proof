#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

worker_url=${WORKER_URL:-https://nix-cf-proof.coy.workers.dev}
token_file=${PROOF_TOKEN_FILE:-receipts/proof-token}

usage() {
  cat >&2 <<'USAGE'
usage:
  vms.sh create [--ubuntu N] [--nixos N] [--prefix NAME]
  vms.sh list
  vms.sh exec NAME COMMAND...
  vms.sh destroy --all
USAGE
  exit 2
}

api() {
  local method=$1 path=$2
  shift 2
  curl -fsS --max-time 900 -X "$method" \
    -H "authorization: Bearer $(cat "$token_file")" \
    -H 'content-type: application/json' \
    "$@" "$worker_url$path"
}

table() {
  jq -r '["NAME","FLAVOR","RUNNING","CONTAINER","OS","KERNEL","PID1","STATE"],
    (.vms[] | [.name, (.flavor // "-"), ((.running // false) | tostring), ((.containerId // "-") | .[0:12]),
      (if .error then ("ERROR " + .error) else ((.osRelease // "-") as $os | ($os | capture("PRETTY_NAME=\"(?<p>[^\"]*)\"").p? // $os)) end),
      (.kernel // "-"), (.pid1 // "-"), (.systemState // "-")]) | @tsv' | column -t -s $'\t'
}

command=${1:-}
[ -n "$command" ] || usage
shift

case $command in
  create)
    ubuntu=0 nixos=0 prefix=vm
    while [ -n "${1:-}" ]; do
      case $1 in
        --ubuntu) ubuntu=$2; shift 2 ;;
        --nixos) nixos=$2; shift 2 ;;
        --prefix) prefix=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    jq -n --argjson ubuntu "$ubuntu" --argjson nixos "$nixos" --arg prefix "$prefix" '{ubuntu: $ubuntu, nixos: $nixos, prefix: $prefix}' |
      api POST /vms --data @- | tee "${VMS_JSON_OUT:-/dev/null}" | table
    ;;
  list)
    api GET /vms | tee "${VMS_JSON_OUT:-/dev/null}" | table
    ;;
  exec)
    [ -n "${2:-}" ] || usage
    name=$1
    shift
    jq -n --arg name "$name" --arg command "$*" '{name: $name, command: $command}' |
      api POST /vms/exec --data @- | jq -r '.stdout, (.stderr | select(length > 0)), "exit \(.exitCode)"'
    ;;
  destroy)
    [ "${1:-}" = --all ] || usage
    api DELETE /vms | jq -c .
    ;;
  *) usage ;;
esac
