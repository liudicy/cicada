#!/usr/bin/env bash
# Builds the release app and packages it in build/:
#   Cicada-<version>-macOS-AppleSilicon.dmg     drag-to-Applications installer (recommended download)
#   Cicada-<version>-macOS-AppleSilicon.zip     the bare app
#   checksums.txt                               SHA-256 of both
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE=1 scripts/build.sh
APP=build/Cicada.app
ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")
[[ "$ID" == com.wquguru.cicada ]] || { echo "Not a release build: $ID" >&2; exit 1; }
VERSION=$(tr -d '[:space:]' < VERSION)
NAME="Cicada-$VERSION-macOS-AppleSilicon"
rm -f build/Cicada-*.zip build/Cicada-*.dmg build/LiveSubs-*.zip build/LiveSubs-*.dmg build/checksums.txt

ditto -c -k --keepParent "$APP" "build/$NAME.zip"

# Installer window background, drawn by the app itself at 1x and 2x.
rm -rf build/dmg && mkdir -p build/dmg
"$APP/Contents/MacOS/Cicada" --render-dmg-background build/dmg/background.png 1
"$APP/Contents/MacOS/Cicada" --render-dmg-background build/dmg/background@2x.png 2
tiffutil -cathidpicheck build/dmg/background.png build/dmg/background@2x.png -out build/dmg/background.tiff 2>/dev/null

# The window layout is a Finder-made .DS_Store kept in the repo (scripts/dmg-template.sh), so
# packaging needs no Finder scripting and works in CI. Without it the DMG still works, just
# without the arranged window. The volume is always named "Cicada".
STAGE=build/dmg/stage
MOUNT=build/dmg/mount
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
# Drop the staged copy so Spotlight and Launch Services don't list a second Cicada.app.
rm -rf "$STAGE" "$MOUNT" build/dmg/rw.dmg

(cd build && shasum -a 256 "$NAME.dmg" "$NAME.zip" > checksums.txt)
echo "Packaged build/$NAME.dmg, build/$NAME.zip, build/checksums.txt"
