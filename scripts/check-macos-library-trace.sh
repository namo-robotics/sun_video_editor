#!/usr/bin/env bash
# Reject build-machine libraries while allowing libraries inside the relocated app.
set -euo pipefail
[[ $# == 2 && $1 == /* ]] || { echo 'Usage: check-macos-library-trace.sh ABSOLUTE_APP LOG' >&2; exit 1; }
[[ -f $2 && -r $2 ]] || { echo "Cannot read library trace: $2" >&2; exit 1; }
contents="${1%/}/Contents"
# Match the full bundle directory literally, including its trailing path separator.
if grep -E '^dyld.*(/opt/homebrew/|/usr/local/|/Users/runner/)' "$2" | grep -Fv " $contents/"; then
  echo 'The app loaded a build-machine library' >&2
  exit 1
fi
