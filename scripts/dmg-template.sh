#!/usr/bin/env bash
# Regenerates Resources/dmg/DS_Store, the installer window layout, by letting Finder lay out a
# scratch volume. Run it on a Mac after changing the window size, icon positions or background;
# keep them in step with Sources/Cicada/DMGBackground.swift. The first run asks to let the
# terminal control Finder (System Settings › Privacy & Security › Automation).
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -d build/Cicada.app && -f build/dmg/background.tiff ]] || { echo "run scripts/package.sh first" >&2; exit 1; }
# A neutral scratch path: Finder records the disk image path in the layout.
WORK=/tmp/cicada-dmg-template
[[ ! -e "/Volumes/Cicada" ]] || { echo "eject the volume named Cicada first" >&2; exit 1; }
rm -rf "$WORK" && mkdir -p "$WORK/stage/.background"
cp -R build/Cicada.app "$WORK/stage/"
ln -s /Applications "$WORK/stage/Applications"
cp build/dmg/background.tiff "$WORK/stage/.background/background.tiff"
hdiutil create -quiet -srcfolder "$WORK/stage" -volname "Cicada" -fs HFS+ -format UDRW -size 60m "$WORK/rw.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$WORK/rw.dmg"

# Window 640 × 520 of content (548 with the title bar); icons at the background's marks.
osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "Cicada"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 668}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Cicada.app" of container window to {170, 175}
    set position of item "Applications" of container window to {470, 175}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

sync
mkdir -p Resources/dmg
cp "/Volumes/Cicada/.DS_Store" Resources/dmg/DS_Store
hdiutil detach "/Volumes/Cicada" -quiet
rm -rf "$WORK"
echo "Updated Resources/dmg/DS_Store"
