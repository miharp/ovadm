#!/usr/bin/env bash
# Print CHANGELOG.md's entry for a version: everything between its heading and
# the next one. Exits 1 if there is none — an unreleased change with no
# changelog entry is the thing that gets skipped, so the tag refuses to ship
# without one.
# Usage: release-notes.sh 0.3.0
set -euo pipefail

version=${1:?usage: release-notes.sh <version>}

notes=$(awk -v v="$version" '
  $0 ~ "^## \\[" v "\\]"          { found = 1; next }
  found && /^## \[/               { exit }
  found && /^\[[^]]+\]: /         { exit }
  found                           { print }
' CHANGELOG.md)

if [ -z "${notes//[[:space:]]/}" ]; then
  echo "::error::CHANGELOG.md has no entry for $version" >&2
  exit 1
fi

printf '%s\n' "$notes"
