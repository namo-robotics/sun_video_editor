#!/bin/sh
# Link the editor or its tests using the selected GTK dependency.
set -efu
# Workspace builds need the same media-enabled GTK as the standalone macOS wrappers.
if [ "$(uname -s)" = Darwin ] && command -v brew >/dev/null 2>&1; then
  gtk_prefix=$(brew --prefix sun-gtk4)
  export PKG_CONFIG_PATH="$gtk_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
flags=$(pkg-config --libs gtk4 librsvg-2.0)
# Split pkg-config's linker flags with filename expansion disabled.
"$SUN_EXECUTABLE" build-compile --dynamic -lm $flags
# Keep direct build outputs runnable with compilers that only stage config resources for installation.
icons="$(dirname "$SUN_OUTPUT")/sun_video_editor_capture.icons"
mkdir -p "$icons"
cp -R packaging/icons/. "$icons/"
