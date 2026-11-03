#!/usr/bin/env bash
# Assemble a self-contained app from tested products; Apple tools relocate native dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'Requires Apple Silicon macOS' >&2; exit 1; }
app='build/macos-app/Sun Video Editor.app'
contents="$app/Contents"
rm -rf build/macos-app build/macos-icon.iconset
mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Resources/share/glib-2.0/schemas" build/macos-icon.iconset
install -m 644 packaging/macos/Info.plist "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$contents/Info.plist"
install -m 755 packaging/macos/launcher.sh "$contents/MacOS/sun-video-editor"
install -m 644 packaging/macos/fonts.conf "$contents/Resources/fonts.conf"
cp -R build/macos/share/sun-video-editor "$contents/Resources/licenses"
cp -R packaging/icons "$contents/Resources/capture-icons"
ln -s ../Resources/capture-icons "$contents/MacOS/sun_video_editor_capture.icons"
# Generate the complete macOS icon family from the existing application artwork.
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" packaging/sun-video-editor.png --out "build/macos-icon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" packaging/sun-video-editor.png --out "build/macos-icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/macos-icon.iconset -o "$contents/Resources/SunVideoEditor.icns"
: > build/macos-seeds.tsv
# Record original paths so loader-relative dependencies resolve before relocation.
seed() {
  printf '%s\t%s\n' "$1" "$2" >> build/macos-seeds.tsv
}
seed "$PWD/build/macos/bin/sun_video_editor" MacOS/sun_video_editor
seed "$PWD/build/macos/bin/sun_video_editor_capture" MacOS/sun_video_editor_capture
seed "$(brew --prefix ffmpeg)/bin/ffmpeg" MacOS/ffmpeg
seed "$(brew --prefix ffmpeg)/bin/ffprobe" MacOS/ffprobe
# The editor's publication and copy commands use GNU command-line options.
for utility in cp mv mktemp; do
  seed "$(brew --prefix coreutils)/libexec/gnubin/$utility" "MacOS/$utility"
done
for utility in realpath ln; do
  seed "$(brew --prefix coreutils)/bin/g$utility" "MacOS/g$utility"
done
pixbuf_prefix=$(brew --prefix gdk-pixbuf)
seed "$pixbuf_prefix/bin/gdk-pixbuf-query-loaders" MacOS/gdk-pixbuf-query-loaders
for library in "$pixbuf_prefix"/lib/gdk-pixbuf-2.0/*/loaders/* "$(brew --prefix librsvg)"/lib/gdk-pixbuf-2.0/*/loaders/*; do
  [[ -f "$library" ]] || continue
  seed "$library" "PlugIns/pixbuf/$(basename "$library")"
done
gstreamer_prefix=$(brew --prefix gstreamer)
seed "$gstreamer_prefix/libexec/gstreamer-1.0/gst-plugin-scanner" MacOS/gst-plugin-scanner
# Local playback and the supported input containers do not need network/device plugins.
for plugin in gio opengl audiofx subparse deinterlace coreelements playback typefindfunctions app audioconvert audioresample autodetect osxaudio videoconvertscale videofilter volume audioparsers videoparsersbad isomp4 matroska avi ogg vorbis opus vpx jpeg png libav; do
  seed "$gstreamer_prefix/lib/gstreamer-1.0/libgst${plugin}.dylib" "PlugIns/gstreamer/libgst${plugin}.dylib"
done
# Some GTK builds install a loadable media backend instead of compiling it in.
gtk_prefix=$(brew --prefix sun-gtk4)
if [[ -d "$gtk_prefix/lib/gtk-4.0" ]]; then
  while IFS= read -r library; do
    seed "$library" "Resources/lib/${library#"$gtk_prefix/lib/"}"
  done < <(find "$gtk_prefix/lib/gtk-4.0" -type f \( -name '*.so' -o -name '*.dylib' \))
fi
for prefix in "$(brew --prefix glib)" "$gtk_prefix"; do
  if [[ -d "$prefix/share/glib-2.0/schemas" ]]; then
    find "$prefix/share/glib-2.0/schemas" -name '*.xml' -exec cp {} "$contents/Resources/share/glib-2.0/schemas/" \;
  fi
done
"$(brew --prefix glib)/bin/glib-compile-schemas" "$contents/Resources/share/glib-2.0/schemas"
python3 scripts/bundle-macos.py "$contents" build/macos-seeds.tsv build/macos-native-files.tsv
# Keep upstream notices, build recipes, and an exact native dependency inventory with the app.
cp build/macos-native-files.tsv "$contents/Resources/licenses/native-files.tsv"
while IFS=$'\t' read -r source relative; do
  case "$source" in
    */Cellar/*)
      keg=${source%/Cellar/*}/Cellar/
      remainder=${source#"$keg"}
      formula=${remainder%%/*}
      remainder=${remainder#*/}
      keg="$keg$formula/${remainder%%/*}"
      notices="$contents/Resources/licenses/$formula"
      if [[ ! -d "$notices" ]]; then
        mkdir -p "$notices"
        find "$keg" -maxdepth 1 -type f \( -iname '*license*' -o -iname '*copying*' -o -iname '*notice*' -o -name 'AUTHORS*' \) -exec cp {} "$notices/" \;
        if [[ -d "$keg/.brew" ]]; then cp -R "$keg/.brew" "$notices/build-recipes"; fi
        if [[ -d "$keg/share/doc" ]]; then cp -R "$keg/share/doc" "$notices/doc"; fi
      fi
      ;;
  esac
done < build/macos-native-files.tsv
# Sign modified libraries and helpers before sealing the enclosing bundle.
signing_identity=${APPLE_SIGNING_IDENTITY:--}
signing_options=(--timestamp=none)
if [[ "$signing_identity" != - ]]; then signing_options=(--options runtime --timestamp); fi
while IFS=$'\t' read -r source relative; do
  codesign --force --sign "$signing_identity" "${signing_options[@]}" "$contents/$relative"
done < build/macos-native-files.tsv
codesign --force --sign "$signing_identity" "${signing_options[@]}" "$app"
codesign --verify --deep --strict "$app"
./scripts/test-macos-app.sh "$app"
ln -s /Applications build/macos-app/Applications
disk_image="build/sun-video-editor-arm64-apple-darwin.dmg"
hdiutil create -ov -format UDZO -volname 'Sun Video Editor' -srcfolder build/macos-app "$disk_image"
if [[ -n ${APPLE_NOTARY_PROFILE:-} ]]; then
  [[ "$signing_identity" != - ]] || { echo 'Notarization requires APPLE_SIGNING_IDENTITY' >&2; exit 1; }
  codesign --force --sign "$signing_identity" --timestamp "$disk_image"
  xcrun notarytool submit "$disk_image" --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$disk_image"
fi
hdiutil verify "$disk_image"
shasum -a 256 "$disk_image" > "$disk_image.sha256"
