#!/usr/bin/env bash
# Builds the release app and packages it in build/:
#   Cicada-<version>-macOS-AppleSilicon.dmg/.zip   Apple silicon (arm64)
#   Cicada-<version>-macOS-Intel.dmg/.zip          Intel (x86_64)
#   checksums.txt                                  SHA-256 of all packaged files
# Set ARCH=arm64 or ARCH=x86_64 to package one architecture; defaults to both ("arm64 x86_64").
# With SIGN_IDENTITY (a Developer ID Application identity) the app and DMG are signed and then
# notarized and stapled, so Gatekeeper opens them without a prompt. Notary credentials: either
# NOTARY_PROFILE (a `notarytool store-credentials` keychain profile) or an App Store Connect API
# key in NOTARY_KEY (path to the .p8), NOTARY_KEY_ID and NOTARY_ISSUER. Without SIGN_IDENTITY
# everything stays ad-hoc signed and unnotarized (pushes to main, forks).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(tr -d '[:space:]' < VERSION)

notarize() {
  [[ -n "${SIGN_IDENTITY:-}" ]] || return 0
  local auth=(--keychain-profile "${NOTARY_PROFILE:-}")
  [[ -n "${NOTARY_PROFILE:-}" ]] || auth=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  xcrun notarytool submit "$1" "${auth[@]}" --wait --timeout 2h --output-format json > build/notary.json
  grep -q '"status" *: *"Accepted"' build/notary.json || {
    cat build/notary.json >&2
    local id; id=$(sed -nE 's/.*"id" *: *"([^"]+)".*/\1/p' build/notary.json)
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${auth[@]}" >&2
    exit 1
  }
}
ARCHS="${ARCH:-arm64 x86_64}"
rm -f build/Cicada-*.zip build/Cicada-*.dmg build/LiveSubs-*.zip build/LiveSubs-*.dmg build/checksums.txt
rm -rf build/dmg && mkdir -p build/dmg

for A in $ARCHS; do
  if [[ "$A" == "x86_64" ]]; then
    SUFFIX="macOS-Intel"
  else
    SUFFIX="macOS-AppleSilicon"
  fi
  NAME="Cicada-$VERSION-$SUFFIX"

  ARCH="$A" RELEASE=1 scripts/build.sh
  APP=build/Cicada.app
  ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")
  [[ "$ID" == com.wquguru.cicada ]] || { echo "Not a release build: $ID" >&2; exit 1; }

  ditto -c -k --keepParent "$APP" "build/$NAME.zip"
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    # Notarize the app itself and staple its ticket, so the copy dragged out of the DMG (and the
    # zip the in-app updater installs) opens offline too; then zip the stapled app again.
    notarize "build/$NAME.zip"
    xcrun stapler staple -q "$APP"
    rm "build/$NAME.zip" && ditto -c -k --keepParent "$APP" "build/$NAME.zip"
  fi

  # Installer window background, drawn by the app itself at 1x and 2x (once per run, using a host binary if cross-compiling).
  if [[ ! -f build/dmg/background.tiff ]]; then
    RENDER_BIN="$APP/Contents/MacOS/Cicada"
    if [[ "$A" != "$(uname -m)" ]]; then
      swift build -c release --product Cicada
      RENDER_BIN="$(swift build -c release --show-bin-path)/Cicada"
    fi
    "$RENDER_BIN" --render-dmg-background build/dmg/background.png 1
    "$RENDER_BIN" --render-dmg-background build/dmg/background@2x.png 2
    tiffutil -cathidpicheck build/dmg/background.png build/dmg/background@2x.png -out build/dmg/background.tiff 2>/dev/null
  fi

  # The window layout is a Finder-made .DS_Store kept in the repo (scripts/dmg-template.sh), so
  # packaging needs no Finder scripting and works in CI. Without it the DMG still works, just
  # without the arranged window. The volume is always named "Cicada".
  STAGE=build/dmg/stage
  MOUNT=build/dmg/mount
  rm -rf "$STAGE" "$MOUNT" build/dmg/rw.dmg
  mkdir -p "$STAGE/.background" "$MOUNT"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp build/dmg/background.tiff "$STAGE/.background/background.tiff"
  [[ -f Resources/dmg/DS_Store ]] && cp Resources/dmg/DS_Store "$STAGE/.DS_Store"
  cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
  hdiutil create -quiet -srcfolder "$STAGE" -volname "Cicada" -fs HFS+ -format UDRW -ov build/dmg/rw.dmg
  hdiutil attach -quiet -readwrite -noverify -noautoopen -nobrowse -mountpoint "$MOUNT" build/dmg/rw.dmg
  SetFile -a C "$MOUNT" 2>/dev/null || true
  hdiutil detach -quiet "$MOUNT"
  hdiutil convert -quiet build/dmg/rw.dmg -format UDZO -imagekey zlib-level=9 -ov -o "build/$NAME.dmg"
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "build/$NAME.dmg"
    notarize "build/$NAME.dmg"
    xcrun stapler staple -q "build/$NAME.dmg"
  fi
  # Drop the staged copy so Spotlight and Launch Services don't list a second Cicada.app.
  rm -rf "$STAGE" "$MOUNT" build/dmg/rw.dmg
done

rm -f build/notary.json
(cd build && shasum -a 256 Cicada-*.dmg Cicada-*.zip > checksums.txt)
echo "Packaged:"
ls -1 build/Cicada-*.dmg build/Cicada-*.zip build/checksums.txt
