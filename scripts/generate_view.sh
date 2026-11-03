#!/bin/sh
# Generate the view with the already-built host tool.
set -eu
ui=$("$SUN_EXECUTABLE" dependency-path --host namo-robotics/sun_ui)
mkdir -p "$SUN_BUILD/generated"
"$ui/bin/sun_viewc" src/sun_video_editor.view.xml "$SUN_BUILD/generated/sun_video_editor.view.sun"
