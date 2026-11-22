#!/usr/bin/env bash
# Usage: scripts/check-version.sh <base-ref>
# VERSION must be MAJOR.MINOR.PATCH. When anything under addon/ changed since <base-ref>, it must
# also be higher than VERSION on <base-ref>, so every addon change ships as a new release.
set -euo pipefail
cd "$(dirname "$0")/.."
base=${1:?usage: check-version.sh <base-ref>}

new=$(tr -d '[:space:]' < VERSION)
[[ $new =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error file=VERSION::VERSION must be MAJOR.MINOR.PATCH, got '$new'"; exit 1; }

if git diff --quiet "$base"...HEAD -- addon/; then
  echo "No changes under addon/; VERSION bump not required."
  exit 0
fi

old=$(git show "$base:VERSION" 2>/dev/null | tr -d '[:space:]' || true)
old=${old:-0.0.0}
highest=$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -n1)
if [[ $new == "$old" || $highest != "$new" ]]; then
  echo "::error file=VERSION::addon/ changed, so VERSION must be higher than $old (it is $new)."
  exit 1
fi
echo "VERSION $old -> $new"
