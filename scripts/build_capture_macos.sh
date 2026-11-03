#!/bin/sh
# Link the macOS capture helper with its framework bindings and application metadata.
set -eu
apple=$("$SUN_EXECUTABLE" dependency-path namo-robotics/sun_apple)
set -- --dynamic -lobjc "-L$apple/lib/native" -lsun_apple_native \
  --link-arg -mmacosx-version-min=26.0 \
  --link-arg "-Wl,-sectcreate,__TEXT,__info_plist,$PWD/packaging/capture-info.plist"
for framework in Foundation AppKit ScreenCaptureKit AVFoundation CoreMedia CoreFoundation CoreGraphics CoreImage CoreVideo ImageIO; do
  set -- "$@" --link-arg -framework --link-arg "$framework"
done
"$SUN_EXECUTABLE" build-compile "$@"
