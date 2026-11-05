#!/usr/bin/env bash
# Prints the release notes for one version: its CHANGELOG.md section, a compare link to the version
# below it, the Chinese changelog on the website, then how to install each platform it ships
# (.github/release-notes-<platform>.md). PLATFORMS (space-separated) overrides the shipped list, as
# the release workflow does when it leaves Android out for want of its signing key.
# scripts/release_notes.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: scripts/release_notes.sh <version>}
awk -v v="$VERSION" '
  /^## / { on = ($2 == v) ; next }
  on { print }
' CHANGELOG.md | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
PREV=$(awk -v v="$VERSION" '/^## / { if (seen) { print $2; exit } if ($2 == v) seen = 1 }' CHANGELOG.md)
echo
echo "---"
echo
[[ -n "$PREV" ]] && echo "**Full changelog**: https://github.com/wquguru/cicada/compare/v$PREV...v$VERSION" && echo
echo "中文更新说明：https://cicada.indaloop.app/changelog/"
echo
for p in ${PLATFORMS:-$(scripts/release_platforms.sh "$VERSION")}; do
  sed "s/<version>/$VERSION/g" ".github/release-notes-$p.md"
done
