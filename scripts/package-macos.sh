#!/usr/bin/env bash
# Package a tested Apple Silicon executable for installation through Homebrew.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'Requires Apple Silicon macOS' >&2; exit 1; }
export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"
./build.sh
mkdir -p build/macos/bin build/macos/share/sun-video-editor
install -m 755 build/sun_video_editor build/macos/bin/sun_video_editor
install -m 755 build/sun_video_editor.capture build/macos/bin/sun_video_editor.capture
mkdir -p build/macos/bin/sun_video_editor.capture.icons
cp -R packaging/icons/. build/macos/bin/sun_video_editor.capture.icons/
install -m 644 LICENSE build/sun-version.txt packaging/sun-video-editor.png build/macos/share/sun-video-editor/
install -m 644 build/dependencies/sun_ui/LICENSE build/macos/share/sun-video-editor/LICENSE.sun_ui
install -m 644 build/dependencies/sun_gobject/LICENSE build/macos/share/sun-video-editor/LICENSE.sun_gobject
apple_source="${SUN_APPLE_SOURCE:-build/dependencies/sun_apple}"
install -m 644 "$apple_source/LICENSE" build/macos/share/sun-video-editor/LICENSE.sun_apple
# Homebrew's opt paths survive dependency upgrades; reject build-machine dependencies.
otool -L build/macos/bin/sun_video_editor > build/macos-linkage.txt
if grep -E '/Users/runner|/private/tmp|/workspaces/' build/macos-linkage.txt; then
  echo 'Executable contains a build-machine library path' >&2
  exit 1
fi
codesign --force --sign - build/macos/bin/sun_video_editor
archive="build/sun-video-editor-${GITHUB_SHA:-local}-arm64-apple-darwin.tar.gz"
tar -C build/macos -czf "$archive" .
shasum -a 256 "$archive" > "$archive.sha256"
