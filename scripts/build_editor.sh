#!/bin/sh
# Link the editor or its tests using the selected GTK dependency.
set -efu
gobject=$("$SUN_EXECUTABLE" dependency-path namo-robotics/sun_gobject)
flags=$(pkg-config --libs gtk4 librsvg-2.0)
# Split pkg-config's linker flags with filename expansion disabled.
"$SUN_EXECUTABLE" build-compile --dynamic "-L$gobject/lib/native" -lsun_gobject_native -lm $flags
