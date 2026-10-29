#!/usr/bin/env bash
# Fetch published dependency packages and normalize their installed files for editor builds.
set -euo pipefail
cd "$(dirname "$0")/.."
asset_directory=
if [[ ${1:-} == --from-directory && $# == 2 ]]; then
  asset_directory=$(realpath "$2")
elif [[ $# != 0 ]]; then
  echo 'Usage: install-dependencies.sh [--from-directory DIRECTORY]' >&2
  exit 1
fi
mkdir -p tmp build/dependencies
staging=$(mktemp -d "$PWD/tmp/releases.XXXXXX")
trap 'rm -rf "$staging"' EXIT
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) platform=linux ;;
  Darwin-arm64) platform=macos ;;
  *) echo 'Release dependencies support Linux x86_64 and macOS arm64.' >&2; exit 1 ;;
esac

./scripts/install-system-dependencies.sh
./scripts/bootstrap-sun.sh
compiler_version=$("${SUN_EXECUTABLE:-sun}" --version 2>&1)

# Keep both installations staged until all required assets have been checked.
for dependency in sun_ui sun_gobject; do
  package=${dependency//_/-}
  if [[ $dependency == sun_ui ]]; then
    release=${SUN_UI_RELEASE:-dev}
  else
    release=${SUN_GOBJECT_RELEASE:-dev}
  fi
  if [[ $platform == linux ]]; then
    asset="${package}_0.dev_amd64.deb"
  else
    asset="${dependency}-arm64-apple-darwin.tar.gz"
  fi
  archive="$staging/$asset"
  if [[ -n $asset_directory ]]; then
    cp "$asset_directory/$asset" "$archive"
  else
    url="https://github.com/namo-robotics/$dependency/releases/download/$release/$asset"
    if ! curl --fail --location --retry 3 "$url" --output "$archive"; then
      echo "Missing published dependency: $url. No source-build fallback is used." >&2
      exit 1
    fi
  fi
  unpack="$staging/unpack-$dependency"
  mkdir -p "$unpack"
  if [[ $platform == linux ]]; then
    dpkg-deb --extract "$archive" "$unpack"
    prefix="$unpack/usr"
    notices="$prefix/share/doc/$package"
    license=copyright
  else
    tar -xzf "$archive" -C "$unpack"
    prefix=$unpack
    notices="$prefix/share/$dependency"
    license=LICENSE
  fi
  if [[ $(cat "$notices/sun-version.txt") != "$compiler_version" ]]; then
    # Producer versions are provenance; Sun checks bundle compatibility when building.
    echo "$dependency was built with a different compiler; Sun will check bundle compatibility during the build:" >&2
    cat "$notices/sun-version.txt" >&2
    printf '\nInstalled compiler: %s\n' "$compiler_version" >&2
  fi
  target="$staging/$dependency"
  mkdir -p "$target/build"
  cp "$prefix/lib/sun/"*.moon "$target/build/"
  cp "$notices/$license" "$target/LICENSE"
  cp "$notices/sun-version.txt" "$target/build/sun-version.txt"
  printf '%s\n' "$release/$asset" > "$target/release.txt"
  if [[ $dependency == sun_ui ]]; then
    test -f "$target/build/sun_ui.moon"
    test -f "$target/build/sun_ui_gtk.moon"
    install -m 755 "$prefix/bin/sun-viewc" "$target/build/sun-viewc"
  else
    test -f "$target/build/sun_gobject.moon"
    test -f "$target/build/sun_gtk.moon"
    mkdir -p "$target/build/native"
    native="$prefix/lib/sun/native/libsun_gobject_native.a"
    if [[ $platform == macos ]]; then native="$prefix/lib/libsun_gobject_native.a"; fi
    cp "$native" "$target/build/native/"
  fi
done
for dependency in sun_ui sun_gobject; do
  rm -rf "build/dependencies/$dependency"
  mv "$staging/$dependency" "build/dependencies/$dependency"
done
echo 'Published dependency bundles, native library, and sun-viewc are ready.'
