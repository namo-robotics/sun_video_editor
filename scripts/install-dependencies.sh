#!/usr/bin/env bash
# Build Git dependency sources and retain license notices for application packaging.
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) dependencies=(sun_ui sun_gobject) ;;
  Darwin-arm64) dependencies=(sun_ui sun_gobject sun_apple) ;;
  *) echo 'Source dependencies support Linux x86_64 and macOS arm64.' >&2; exit 1 ;;
esac
if (($#)); then
  if [[ $# != 2 || $1 != --only ]]; then
    echo 'Usage: install-dependencies.sh [--only sun_ui|sun_gobject|sun_apple]' >&2
    exit 1
  fi
  case " ${dependencies[*]} " in
    *" $2 "*) dependencies=("$2") ;;
    *) echo "Unsupported dependency for this host: $2" >&2; exit 1 ;;
  esac
fi
./scripts/install-system-dependencies.sh
./scripts/bootstrap-sun.sh
compiler=${SUN_EXECUTABLE:-sun}
# Use HTTPS for public CI fetches without changing developer Git configuration.
if [[ ${CI:-} == true ]]; then
  export GIT_CONFIG_COUNT=$((${GIT_CONFIG_COUNT:-0} + 1))
  export "GIT_CONFIG_KEY_$((GIT_CONFIG_COUNT - 1))=url.https://github.com/.insteadOf"
  export "GIT_CONFIG_VALUE_$((GIT_CONFIG_COUNT - 1))=git@github.com:"
fi
if [[ $(uname -s) == Darwin ]] && command -v brew >/dev/null; then
  export PKG_CONFIG_PATH="$(brew --prefix sun-gtk4)/lib/pkgconfig:$(brew --prefix libffi)/lib/pkgconfig:$(brew --prefix)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
export SUN_DEPENDENCY_CACHE="${SUN_DEPENDENCY_CACHE:-$PWD/build/dependencies/cache}"
for dependency in "${dependencies[@]}"; do
  # Resolve prints build progress before its final JSON record. Keep that output
  # visible in CI while passing only the result to the JSON parser.
  root=$("$compiler" resolve --config sun-config.json --dependency "namo-robotics/$dependency" |
    python3 -c 'import json, sys
lines = sys.stdin.read().splitlines()
for line in lines:
    print(line, file=sys.stderr)
print(json.loads(lines[-1] if lines else "")["root"])')
  mkdir -p "build/dependencies/$dependency"
  install -m 644 "$root/share/$dependency/LICENSE" "build/dependencies/$dependency/LICENSE"
done
echo 'Source dependencies are built and license notices are ready.'
