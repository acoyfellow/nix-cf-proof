work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c core.hooksPath=/dev/null -c user.name=probe -c user.email=probe@example.com -c init.defaultBranch=main "$@"; }

g init -q --bare "$work/remote.git"
g clone -q "$work/remote.git" "$work/clone" 2>/dev/null
cd "$work/clone"
echo one > file
g add file
g commit -qm one
g push -q origin HEAD:main
echo two > file
g commit -qam two
g push -q origin HEAD:main || { echo "FAIL fast-forward push was refused"; exit 1; }
echo "allowed fast-forward git push origin HEAD:main"
echo three > file
g commit -qa --amend -m rewritten

remote_tip_before=$(g --git-dir="$work/remote.git" rev-parse main)
refused=0
expect_refused() {
  local label=$1
  shift
  if output=$("$@" 2>&1); then
    echo "FAIL $label succeeded"
    exit 1
  fi
  echo "$output" | grep -q "is disabled and not allowed" || { echo "FAIL $label: $output"; exit 1; }
  echo "refused $label"
  refused=$((refused + 1))
}

expect_refused "git push --force" g push --force origin HEAD:main
expect_refused "git push -f" g push -f origin HEAD:main
expect_refused "git push --force-with-lease" g push --force-with-lease origin HEAD:main
expect_refused "git push origin +HEAD:main" g push origin +HEAD:main
expect_refused "git push with +refspec from config" g -c remote.origin.push=+HEAD:refs/heads/main push origin
expect_refused "git push --mirror" g push --mirror origin

[ "$(g --git-dir="$work/remote.git" rev-parse main)" = "$remote_tip_before" ] || { echo "FAIL remote history changed"; exit 1; }
echo "remote main unchanged at $remote_tip_before"
echo "FORCE_PUSH_REFUSED=$refused"
