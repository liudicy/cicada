#!/usr/bin/env bash
# Prints the platforms one version ships, one per line (mac, windows, android, linux): those with a
# group in its CHANGELOG.md section (scripts/changelog.py). Since 1.1.2 every section has all four
# (every release ships every platform); 1.0.0 to 1.1.1 shipped only the ones that changed.
# A section written by hand without platform groups (1.0.0's "### Highlights") ships the Mac app.
# scripts/release_platforms.sh 1.1.0
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: scripts/release_platforms.sh <version>}
awk -v v="$VERSION" '
  /^## / { on = ($2 == v); if (on) found = 1; next }
  on && /^### (Mac|Windows|Android|Linux)$/ { print tolower($2); n++ }
  END { if (!found) exit 1; if (!n) print "mac" }
' CHANGELOG.md || { echo "no CHANGELOG.md section for $VERSION" >&2; exit 1; }
