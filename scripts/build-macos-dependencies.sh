#!/usr/bin/env bash
# Build the editor's dependencies through their native Apple Silicon entry points.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/bootstrap-sun.sh
./src/sun_gobject/scripts/build-macos.sh --bundles
SUN_GOBJECT_BUILD="$PWD/src/sun_gobject/build" ./src/sun_ui/scripts/build-macos.sh --bundles
