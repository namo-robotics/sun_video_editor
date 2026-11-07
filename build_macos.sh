#!/usr/bin/env bash
# Build the Apple Silicon editor and capture helper with their source dependencies.
set -euo pipefail
cd "$(dirname "$0")"
if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
  echo 'This build requires Apple Silicon macOS.' >&2
  exit 1
fi
./scripts/bootstrap-sun.sh
export PKG_CONFIG_PATH="$(brew --prefix sun-gtk4)/lib/pkgconfig:$(brew --prefix libffi)/lib/pkgconfig:$(brew --prefix)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
exec "${SUN_EXECUTABLE:-sun}" build --config sun-config.json \
  --target arm64-apple-darwin --package namo-robotics/sun_video_editor --no-test
