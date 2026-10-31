#!/usr/bin/env bash
# Verify relocation, signatures, media tools, and GTK behavior from the packaged app.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 1 ]] || { echo 'Usage: test-macos-app.sh APP' >&2; exit 1; }
# A second location with spaces catches accidental dependencies on the staging path.
rm -rf 'build/macos-app-test'
mkdir -p 'build/macos-app-test'
relocated="$PWD/build/macos-app-test/Sun Video Editor.app"
ditto "$1" "$relocated"
contents="$relocated/Contents"
plutil -lint "$contents/Info.plist"
codesign --verify --deep --strict "$relocated"
while IFS=$'\t' read -r source relative; do
  while IFS= read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/Library/*) ;;
      @loader_path/*)
        test -f "$(dirname "$contents/$relative")/${dependency#@loader_path/}"
        ;;
      *) echo "External dependency in $relative: $dependency" >&2; exit 1 ;;
    esac
  done < <(otool -L "$contents/$relative" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility version.*$//')
  if otool -l "$contents/$relative" | grep 'cmd LC_RPATH' >/dev/null; then
    echo "Unsealed runtime search path in $relative" >&2
    exit 1
  fi
done < build/macos-native-files.tsv
launcher="$contents/MacOS/sun-video-editor"
# Do not inherit PATH, DYLD, or plugin settings from the build machine.
env -i HOME="$HOME" PATH=/usr/bin:/bin "$launcher" --check-dependencies
env -i HOME="$HOME" PATH=/usr/bin:/bin "$contents/MacOS/sun_video_editor.capture" --self-test
"$(brew --prefix coreutils)/bin/gtimeout" 60s env -i HOME="$HOME" PATH=/usr/bin:/bin \
  SUN_EDITOR_TEST_RESIZE="${SUN_EDITOR_TEST_RESIZE:-0}" G_DEBUG=fatal-criticals GTK_A11Y=none GSK_RENDERER=cairo GST_DEBUG=2 GST_DEBUG_NO_COLOR=1 \
  SUN_EDITOR_TRACE_LIBRARIES=1 "$launcher" --self-test > build/macos-app-acceptance.log 2>&1
tail -n 20 build/macos-app-acceptance.log
bash scripts/check-macos-library-trace.sh "$relocated" build/macos-app-acceptance.log
