set -eu
. /tmp/ci.env

output_path() {
  nix eval --raw --impure --expr "builtins.getAttr \"$1\" (builtins.fromJSON (builtins.readFile /tmp/build.json))"
}

sandbox=$(output_path outputs.sandbox)
git=$(output_path outputs.git)
nixos=$(output_path outputs.nixos)

mkdir -p /out/proof /out/nix/store /out/tmp /out/bin
chmod 1777 /out/tmp
cp -a $(nix-store -qR "$sandbox" "$nixos") /out/nix/store/
ln -s "$sandbox" /out/sandbox
ln -s "$nixos" /out/nixos-system
ln -s "$nixos/init" /out/init
ln -s "$sandbox/bin/bash" /out/bin/sh
cp /tmp/build.json /out/proof/build.json

cat > /out/proof/build-receipt.json <<JSON
{"builder_uname":"$(uname -a)","built_at":"$(date -u +%FT%TZ)","git_store_path":"$git","sandbox_store_path":"$sandbox","nixos_toplevel":"$nixos","workers_ci":"$WORKERS_CI","workers_ci_build_uuid":"$WORKERS_CI_BUILD_UUID","workers_ci_commit_sha":"$WORKERS_CI_COMMIT_SHA","workers_ci_branch":"$WORKERS_CI_BRANCH"}
JSON
cat /out/proof/build-receipt.json
