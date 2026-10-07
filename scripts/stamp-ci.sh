#!/bin/sh
set -eu
test "${WORKERS_CI:-}" = "1" || { echo "stamp-ci: refusing to run outside Workers Builds"; exit 1; }
cat > container/ci.env <<ENV
WORKERS_CI='${WORKERS_CI}'
WORKERS_CI_BUILD_UUID='${WORKERS_CI_BUILD_UUID:-}'
WORKERS_CI_COMMIT_SHA='${WORKERS_CI_COMMIT_SHA:-}'
WORKERS_CI_BRANCH='${WORKERS_CI_BRANCH:-}'
ENV
cat container/ci.env
