#!/usr/bin/env bash
# Builds build/Cicada.app (Apple silicon or Intel via ARCH=arm64|x86_64, default: host arch).
# Shown as 知了 on Chinese systems, Cicada elsewhere.
# Without RELEASE=1 it is a dev build: "知了 Dev" / "Cicada Dev", bundle id com.wquguru.cicada.dev (its own
# settings, permissions and meeting records), stamped with the branch and commit, which show in the
# menu bar and panel; its icon carries a "DEV" band. RELEASE=1 builds the real com.wquguru.cicada.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${ARCH:-$(uname -m)}"
swift build -c release --arch "$ARCH" --product Cicada
swift build -c release --product CicadaIcon
BIN=$(swift build -c release --arch "$ARCH" --show-bin-path)
HOST_BIN=$(swift build -c release --show-bin-path)

APP=build/Cicada.app
ICONSET=build/AppIcon.iconset
rm -rf "$APP" "$ICONSET" build/LiveSubs.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Cicada" "$APP/Contents/MacOS/Cicada"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/sample/sample.m4a "$APP/Contents/Resources/"
# The experimental voiceprint model; the app compiles it on first use (no coremlcompiler in the CLT).
cp -R Resources/models/SpeakerEmbedding.mlpackage "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# Traditional Chinese systems get the Chinese UI rather than English (there is no zh-Hant translation).
cp -R Resources/zh-Hans.lproj "$APP/Contents/Resources/zh-Hant.lproj"

PLIST="$APP/Contents/Info.plist"
# One version for every platform, in VERSION at the repo root (the committed Info.plist value is unused).
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(tr -d '[:space:]' < VERSION)" "$PLIST"
if [[ "${RELEASE:-}" != 1 ]]; then
  STAMP="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo local) @ $(git rev-parse --short HEAD 2>/dev/null || echo none)"
  [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]] && STAMP+="+"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.wquguru.cicada.dev" \
    -c "Set :CFBundleName Cicada Dev" -c "Set :CFBundleDisplayName Cicada Dev" \
    -c "Add :LiveSubsDev string $STAMP" "$PLIST"
  # Only the two name lines change: the usage descriptions in the same files stay.
  sed -i '' -E 's/^(CFBundle(Display)?Name = ")([^"]*)";/\1\3 Dev";/' \
    "$APP"/Contents/Resources/*.lproj/InfoPlist.strings
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi

ICON_FLAGS=()
[[ "${RELEASE:-}" == 1 ]] || ICON_FLAGS=(--dev)
"$HOST_BIN/CicadaIcon" ${ICON_FLAGS[@]+"${ICON_FLAGS[@]}"} "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# A fixed designated requirement (the bundle id alone), so rebuilding keeps the system-audio and
# microphone permissions instead of asking again after every build. A Developer ID signature
# (SIGN_IDENTITY, set for releases) keeps the same requirement: permissions granted to the earlier
# ad-hoc builds carry over. It adds the hardened runtime and a timestamp, which notarization needs.
ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$PLIST")
SIGN_FLAGS=(--sign -)
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  SIGN_FLAGS=(--sign "$SIGN_IDENTITY" --options runtime --timestamp --entitlements Resources/Cicada.entitlements)
fi
codesign --force "${SIGN_FLAGS[@]}" --requirements "=designated => identifier \"$ID\"" "$APP" >/dev/null
echo "Built $APP ($ID, signed by ${SIGN_IDENTITY:-ad hoc})"
