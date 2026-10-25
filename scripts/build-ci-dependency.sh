#!/usr/bin/env bash
# Build sun_gobject and run its tests sequentially to avoid competing Xvfb startups.
set -euo pipefail
cd "$(dirname "$0")/../src/sun_gobject"
./scripts/bootstrap-sun.sh
parallel_jobs=$(($(nproc) / 2))
if ((parallel_jobs < 1)); then parallel_jobs=1; fi
if [[ -n ${BUILD_JOBS:-} ]] && ((BUILD_JOBS < parallel_jobs)); then parallel_jobs=$BUILD_JOBS; fi
cmake -S native --preset "${CMAKE_PRESET:-dev-fast}"
cmake --build build/native -j "$parallel_jobs"
"${SUN_EXECUTABLE:-sun}" tools/build.sun -- build
# The dependency's test task does not forward arguments to its test executable.
build/sun-gobject-tests_test --test-sequential 2>&1 | tee build/test-results.log
