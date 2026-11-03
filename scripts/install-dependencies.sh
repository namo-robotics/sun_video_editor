#!/usr/bin/env bash
# Resolve published Sun packages and retain license notices for application packaging.
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) dependencies=(sun_ui sun_gobject) ;;
  Darwin-arm64) dependencies=(sun_ui sun_gobject sun_apple) ;;
  *) echo 'Release dependencies support Linux x86_64 and macOS arm64.' >&2; exit 1 ;;
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
export SUN_DEPENDENCY_CACHE="${SUN_DEPENDENCY_CACHE:-$PWD/build/dependencies/cache}"
for dependency in "${dependencies[@]}"; do
  resolved=$("$compiler" resolve --config sun-config.json --dependency "namo-robotics/$dependency")
  root=$(printf '%s\n' "$resolved" | python3 -c 'import json,sys; print(json.load(sys.stdin)["root"])')
  mkdir -p "build/dependencies/$dependency"
  license="$root/share/$dependency/LICENSE"
  if [[ -f "$license" ]]; then
    install -m 644 "$license" "build/dependencies/$dependency/LICENSE"
  else
    # Older sun_gobject packages omit their license; retain the release's notice.
    curl --fail --location --retry 3 \
      "https://raw.githubusercontent.com/namo-robotics/$dependency/dev/LICENSE" \
      --output "build/dependencies/$dependency/LICENSE"
  fi
done
echo 'Published Sun packages are resolved and license notices are ready.'
