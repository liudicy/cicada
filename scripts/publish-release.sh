#!/usr/bin/env bash
# Makes a draft release public once its files have been tried: scripts/publish-release.sh 1.0.1
# The release workflow leaves every new release a draft, so no update check offers it before this.
# It is marked latest only when it has the Mac app: Macs on 1.0.0 read releases/latest. Since 1.1.2
# every release ships every platform, so that is every release; 1.1.1 (Android only) was not.
set -euo pipefail
VERSION=${1:?usage: scripts/publish-release.sh <version, e.g. 1.0.1>}
TAG="v$VERSION"
REPO=wquguru/cicada
[[ "$(gh release view "$TAG" -R "$REPO" --json isDraft -q .isDraft)" == true ]] || { echo "$TAG is not a draft" >&2; exit 1; }
assets=$(gh release view "$TAG" -R "$REPO" --json assets -q '.assets[].name')
echo "$assets"
latest=false; grep -q '\.dmg$' <<< "$assets" && latest=true
read -r -p "Publish $TAG (latest: $latest)? [y/N] " ok
[[ "$ok" == y ]] || exit 1
gh release edit "$TAG" -R "$REPO" --draft=false --latest=$latest
echo "Published https://github.com/$REPO/releases/tag/$TAG"
