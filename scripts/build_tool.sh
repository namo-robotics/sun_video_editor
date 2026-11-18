#!/bin/sh
# Use Sun defaults: static musl on Linux and native system linking on macOS.
set -eu
"$SUN_EXECUTABLE" build-compile
