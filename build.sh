#!/usr/bin/env bash
# Build, test, or package the editor from its own workspace root.
set -euo pipefail
cd "$(dirname "$0")"
./scripts/bootstrap-sun.sh
if [[ $(uname -s) == Darwin ]] && command -v brew >/dev/null; then
  export PKG_CONFIG_PATH="$(brew --prefix sun-gtk4)/lib/pkgconfig:$(brew --prefix libffi)/lib/pkgconfig:$(brew --prefix)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
case "${1:-}" in
  "") "${SUN_EXECUTABLE:-sun}" src/tools/build.sun -- build; "${SUN_EXECUTABLE:-sun}" src/tools/build.sun -- test ;;
  --build|--test|--package) "${SUN_EXECUTABLE:-sun}" src/tools/build.sun -- "${1#--}" ;;
  *) echo 'Usage: ./build.sh [--build|--test|--package]' >&2; exit 1 ;;
esac
