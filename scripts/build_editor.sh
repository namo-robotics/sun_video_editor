#!/bin/sh
# Link the editor or its tests using the selected GTK dependency.
set -efu
flags=$(pkg-config --libs gtk4 librsvg-2.0)
# Split pkg-config's linker flags with filename expansion disabled.
"$SUN_EXECUTABLE" build-compile --dynamic -lm $flags
