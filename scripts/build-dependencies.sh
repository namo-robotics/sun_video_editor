#!/usr/bin/env bash
# Build the two explicitly imported dependencies without recursively importing applications.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/bootstrap-sun.sh
if [[ ! -f src/sun_ui/build.sh || ! -f src/sun_gobject/build.sh ]]; then
  echo 'Run vcs import --input deps.repos . first.' >&2
  exit 1
fi
bash scripts/build-ci-dependency.sh
export SUN_GOBJECT_BUILD="$PWD/src/sun_gobject/build"
./src/sun_ui/build.sh --gtk
