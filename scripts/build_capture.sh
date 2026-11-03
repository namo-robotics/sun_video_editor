#!/bin/sh
# Link Linux capture targets against the selected bindings and system libraries.
set -efu
gobject=$("$SUN_EXECUTABLE" dependency-path namo-robotics/sun_gobject)
flags=$(pkg-config --libs gio-unix-2.0 gstreamer-1.0 gstreamer-video-1.0 x11 xext)
# Split pkg-config's linker flags with filename expansion disabled.
"$SUN_EXECUTABLE" build-compile --dynamic "-L$gobject/lib/native" -lsun_capture_native $flags
