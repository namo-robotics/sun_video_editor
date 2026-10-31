#!/usr/bin/env bash
# Install host tools needed to build, test, run, and package the editor.
set -euo pipefail
cd "$(dirname "$0")/.."

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    command -v apt-get >/dev/null || { echo 'System setup requires Ubuntu 26.04 with apt-get.' >&2; exit 1; }
    packages=(ca-certificates curl build-essential pkg-config libgtk-4-dev librsvg2-2
      fonts-dejavu-core fonts-noto-core ffmpeg gstreamer1.0-libav gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly gstreamer1.0-pipewire libgstreamer1.0-dev libx11-dev libxext-dev
      xvfb xauth dbus-x11 dpkg-dev)
    missing=()
    for package in "${packages[@]}"; do
      if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) != 'install ok installed' ]]; then
        missing+=("$package")
      fi
    done
    if ((${#missing[@]})); then
      echo "Installing system dependencies: ${missing[*]}"
      elevate=()
      if [[ $(id -u) != 0 ]]; then
        command -v sudo >/dev/null || { echo 'Install sudo or run this system setup script as root.' >&2; exit 1; }
        elevate=(sudo)
      fi
      "${elevate[@]}" apt-get update
      "${elevate[@]}" apt-get install -y "${missing[@]}"
    fi
    ;;
  Darwin-arm64)
    command -v brew >/dev/null || { echo 'Install Homebrew, then rerun scripts/install-dependencies.sh.' >&2; exit 1; }
    for formula in namo-robotics/sun/sun-gtk4 librsvg gstreamer ffmpeg coreutils pkgconf; do
      if ! brew list --versions "$formula" >/dev/null 2>&1; then
        brew install "$formula"
      fi
    done
    ;;
  *) echo 'System setup supports Linux x86_64 and macOS arm64.' >&2; exit 1 ;;
esac

# Older distribution packages cannot satisfy the editor's media requirements.
for tool in ffmpeg ffprobe; do
  version=$("$tool" -version)
  if [[ ! $version =~ version\ ([0-9]+)\. ]] || (( BASH_REMATCH[1] < 8 )); then
    echo "$tool 8 or newer is required. Use Ubuntu 26.04 or upgrade the Homebrew ffmpeg formula, then rerun setup." >&2
    exit 1
  fi
done
