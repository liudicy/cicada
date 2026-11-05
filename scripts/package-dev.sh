#!/usr/bin/env bash
# Packages the fork build (dev bundle id com.wquguru.cicada.dev, rebranded "Cicada MOD") in build/:
#   Cicada-Dev-<fver>-macOS-AppleSilicon.dmg     drag-to-Applications installer
#   Cicada-Dev-<fver>-macOS-AppleSilicon.zip     the bare app
#   checksums-dev.txt                            SHA-256 of both
#
#   scripts/package-dev.sh              build + package
#   scripts/package-dev.sh -r           also publish a GitHub pre-release on the fork
#   scripts/package-dev.sh -r v1.1.1.2  …with this tag instead of the auto-bumped one
#
# <fver> is the upstream version plus a fork serial (1.1.1.1, 1.1.1.2, …): the running app
# is stamped with it (CFBundleShortVersionString + LiveSubsFork) so update checks against the
# fork's releases compare cleanly, and Updater's exact version match still works. The stamp is
# re-signed with the same ad-hoc designated requirement, so permissions carry over.
#
# Publishing needs gh (logged in) and network access to github.com; if that needs a proxy,
# export HTTPS_PROXY first, e.g.  HTTPS_PROXY=http://127.0.0.1:7890 scripts/package-dev.sh -r
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE=0
TAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--release) RELEASE=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) TAG="$1"; shift ;;
    esac
done
[[ -n "$TAG" && $RELEASE -eq 0 ]] && { echo "A tag only makes sense with -r." >&2; exit 1; }

# The dev build keeps its own bundle id and data, so it installs next to the release app.
# xcode-select may point at CLT without the SwiftUI macros; prefer full Xcode when present.
[[ -d /Applications/Xcode.app ]] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build.sh
APP=build/Cicada.app
PLIST="$APP/Contents/Info.plist"
ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$PLIST")
[[ "$ID" == com.wquguru.cicada.dev ]] || { echo "Not a dev build: $ID" >&2; exit 1; }
VERSION=$(tr -d '[:space:]' < VERSION)

# The fork version: a manual tag wins; otherwise v<version>.<n+1>, counting the fork's existing
# releases. Offline without -r, stamp .0 (never offered as an update, clearly a local package).
if [[ -n "$TAG" ]]; then
    FVER="${TAG#v}"
elif LAST=$(gh release list --repo liudicy/cicada --limit 100 --json tagName --jq '.[].tagName' 2>/dev/null); then
    LAST=$(echo "$LAST" | { grep -E "^v${VERSION//./\\.}\.[0-9]+$" || true; } | sort -t. -k4 -n | tail -1)
    FVER=$([[ -n "$LAST" ]] && echo "$VERSION.$(( ${LAST##*.} + 1 ))" || echo "$VERSION.1")
else
    [[ $RELEASE -eq 1 ]] && { echo "Cannot reach GitHub to pick the next tag." >&2; exit 1; }
    FVER="$VERSION.0"
    echo "GitHub unreachable: stamping local-only version $FVER"
fi
TAG="v$FVER"
NAME="Cicada-Dev-$FVER-macOS-AppleSilicon"

# Stamp the fork version into the app the packages are made from, then re-seal: the ad-hoc
# signature covers Info.plist, and Updater verifies the downloaded app with --deep --strict.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $FVER" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :LiveSubsFork" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LiveSubsFork string $FVER" "$PLIST"
codesign --force --sign - --requirements "=designated => identifier \"$ID\"" "$APP" >/dev/null

# The published package is rebranded "Cicada MOD" (display name + MOD icon band) on a copy, so
# the dev build in build/Cicada.app stays "Cicada Dev" for local driving. Bundle id, data,
# permissions and the update feed (the Cicada-Dev-* asset names) are deliberately unchanged.
MODAPP="build/Cicada MOD.app"
ICONSET=build/AppIcon-mod.iconset
rm -rf "$MODAPP" "$ICONSET"
cp -R "$APP" "$MODAPP"
BIN=$(swift build -c release --show-bin-path)
"$BIN/LiveSubsIcon" --band MOD "$ICONSET"
iconutil -c icns "$ICONSET" -o "$MODAPP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Cicada MOD" -c "Set :CFBundleDisplayName Cicada MOD" "$MODAPP/Contents/Info.plist"
sed -i '' -E 's/ Dev";/ MOD";/' "$MODAPP"/Contents/Resources/*.lproj/InfoPlist.strings
codesign --force --sign - --requirements "=designated => identifier \"$ID\"" "$MODAPP" >/dev/null

rm -f build/Cicada-Dev-*.dmg build/Cicada-Dev-*.zip build/checksums-dev.txt

ditto -c -k --keepParent "$MODAPP" "build/$NAME.zip"

# Same installer window as the release DMG: background drawn by the app itself, layout from
# the repo's .DS_Store, staged as "Cicada MOD.app" so it never overwrites the release app.
rm -rf build/dmg-dev && mkdir -p build/dmg-dev/stage/.background build/dmg-dev/mount
"$APP/Contents/MacOS/Cicada" --render-dmg-background build/dmg-dev/background.png 1
"$APP/Contents/MacOS/Cicada" --render-dmg-background build/dmg-dev/background@2x.png 2
tiffutil -cathidpicheck build/dmg-dev/background.png build/dmg-dev/background@2x.png -out build/dmg-dev/background.tiff 2>/dev/null
cp -R "$MODAPP" "build/dmg-dev/stage/Cicada MOD.app"
ln -s /Applications build/dmg-dev/stage/Applications
cp build/dmg-dev/background.tiff build/dmg-dev/stage/.background/background.tiff
[[ -f Resources/dmg/DS_Store ]] && cp Resources/dmg/DS_Store build/dmg-dev/stage/.DS_Store
cp "$MODAPP/Contents/Resources/AppIcon.icns" build/dmg-dev/stage/.VolumeIcon.icns
hdiutil create -quiet -srcfolder build/dmg-dev/stage -volname "Cicada MOD" -fs HFS+ -format UDRW -ov build/dmg-dev/rw.dmg
hdiutil attach -quiet -readwrite -noverify -noautoopen -nobrowse -mountpoint build/dmg-dev/mount build/dmg-dev/rw.dmg
SetFile -a C build/dmg-dev/mount 2>/dev/null || true
hdiutil detach -quiet build/dmg-dev/mount
hdiutil convert -quiet build/dmg-dev/rw.dmg -format UDZO -imagekey zlib-level=9 -ov -o "build/$NAME.dmg"
# Drop the staged and MOD copies so Spotlight and Launch Services don't list extra apps.
rm -rf build/dmg-dev "$MODAPP" "$ICONSET"

(cd build && shasum -a 256 "$NAME.dmg" "$NAME.zip" > checksums-dev.txt)
echo "Packaged build/$NAME.dmg, build/$NAME.zip, build/checksums-dev.txt"

[[ $RELEASE -eq 0 ]] && exit 0
command -v gh >/dev/null || { echo "gh not found; upload the files in build/ by hand." >&2; exit 1; }

# The tag points at the commit being packaged, so push first.
git push origin main
NOTES=$(cat <<EOF
## 这是什么

个人 fork 的打包版，基于上游 v$VERSION，额外包含：云端语音识别校对（预置小米 MiMo）、纪要编辑与重新整理、删除录音与存储空间页、侧栏「开始听」三入口布局。现场会议、导入录音、自定义模型服务商已并入上游官方实现。

## 安装

拖拽 \`Cicada MOD.app\` 到「应用程序」即可，与上游正式版并存、数据互不影响。个人 ad-hoc 签名，首次打开如被 Gatekeeper 拦截，在终端执行：

\`\`\`sh
xattr -dr com.apple.quarantine "/Applications/Cicada MOD.app"
\`\`\`

仅限 Apple 芯片 Mac，macOS 14.4+。校验值见 checksums-dev.txt。
EOF
)
gh release create "$TAG" --repo liudicy/cicada --prerelease \
    --title "v$VERSION + fork 定制（Cicada MOD $FVER）" --notes "$NOTES" \
    "build/$NAME.dmg" "build/$NAME.zip" build/checksums-dev.txt
echo "Published https://github.com/liudicy/cicada/releases/tag/$TAG"
