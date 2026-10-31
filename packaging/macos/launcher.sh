#!/bin/bash
# Launch with only bundled media tools and plugins, independent of a terminal or Homebrew.
set -euo pipefail
contents=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$contents/MacOS:/usr/bin:/bin:/usr/sbin:/sbin"
export GST_PLUGIN_SYSTEM_PATH_1_0="$contents/PlugIns/gstreamer"
export GST_PLUGIN_PATH_1_0="$GST_PLUGIN_SYSTEM_PATH_1_0"
export GST_PLUGIN_SCANNER="$contents/MacOS/gst-plugin-scanner"
export XDG_DATA_DIRS="$contents/Resources/share"
export GSETTINGS_SCHEMA_DIR="$contents/Resources/share/glib-2.0/schemas"
export FONTCONFIG_FILE="$contents/Resources/fonts.conf"
export GIO_MODULE_DIR="$contents/Frameworks/gio/modules"
export GTK_PATH="$contents/Resources/lib/gtk-4.0"
export GDK_PIXBUF_MODULEDIR="$contents/PlugIns/pixbuf"
# Loader caches contain absolute paths, so regenerate them for the installed location.
cache="$HOME/Library/Caches/org.namo-robotics.SunVideoEditor"
mkdir -p "$cache"
location=$(printf '%s' "$contents" | /usr/bin/cksum | /usr/bin/cut -d ' ' -f 1)
export GDK_PIXBUF_MODULE_FILE="$cache/pixbuf-$location.cache"
loader_cache=$(mktemp "$cache/pixbuf.XXXXXX")
"$contents/MacOS/gdk-pixbuf-query-loaders" "$GDK_PIXBUF_MODULEDIR"/* > "$loader_cache"
mv -f "$loader_cache" "$GDK_PIXBUF_MODULE_FILE"
# Keep plugin registries separate from other installed GStreamer versions.
export GST_REGISTRY="$HOME/Library/Caches/org.namo-robotics.SunVideoEditor/gstreamer.bin"
mkdir -p "$(dirname "$GST_REGISTRY")"
if [[ ${SUN_EDITOR_TRACE_LIBRARIES:-0} == 1 ]]; then export DYLD_PRINT_LIBRARIES=1; fi
exec "$contents/MacOS/sun_video_editor" "$@"
