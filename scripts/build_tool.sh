#!/bin/sh
# Link build tooling against the host libraries without requiring a static toolchain.
set -eu
"$SUN_EXECUTABLE" build-compile --dynamic
