#!/usr/bin/env bash
# Clone missing dependency sources without updating existing working trees.
set -euo pipefail
cd "$(dirname "$0")/.."
# deps.repos uses JSON, a YAML subset, so setup needs only Python's standard library.
manifest=$(python3 - <<'PY'
import json
with open('deps.repos') as source:
    for path, repository in json.load(source)['repositories'].items():
        print(path, repository['url'], repository['version'], sep='\t')
PY
)
while IFS=$'\t' read -r path url revision; do
  if [[ $path == src/sun_apple && $(uname -s) != Darwin ]]; then continue; fi
  if [[ -e $path || -L $path ]]; then
    [[ -e $path/.git && -f $path/sun-config.json ]] || { echo "Expected a Git checkout with sun-config.json in $path" >&2; exit 1; }
    echo "Keeping existing checkout: $path"
    continue
  fi
  # Public CI jobs use HTTPS without changing the SSH URLs used by developers.
  if [[ ${CI:-} == true ]]; then url="${url/git@github.com:/https:\/\/github.com/}"; fi
  git clone --branch "$revision" --single-branch "$url" "$path"
done <<< "$manifest"
