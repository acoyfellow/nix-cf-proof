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
g commit -qa --amend -m rewritten

refused=0
for args in "--force origin HEAD:main" "-f origin HEAD:main" "--force-with-lease origin HEAD:main" "origin +HEAD:main"; do
  read -r -a argv <<< "$args"
  if output=$(g push "${argv[@]}" 2>&1); then
    echo "FAIL git push $args succeeded"
    exit 1
  fi
  echo "$output" | grep -q "is disabled and not allowed" || { echo "FAIL git push $args: $output"; exit 1; }
  echo "refused git push $args"
  refused=$((refused + 1))
done
echo "FORCE_PUSH_REFUSED=$refused"
