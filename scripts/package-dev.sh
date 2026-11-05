#!/usr/bin/env bash
# Packages the dev build (com.wquguru.cicada.dev, "Cicada Dev") in build/:
#   Cicada-Dev-<version>-macOS-AppleSilicon.dmg     drag-to-Applications installer
#   Cicada-Dev-<version>-macOS-AppleSilicon.zip     the bare app
#   checksums-dev.txt                               SHA-256 of both
#
#   scripts/package-dev.sh              build + package
#   scripts/package-dev.sh -r           also publish a GitHub pre-release on the fork
#   scripts/package-dev.sh -r v1.1.1-fork.2    …with this tag instead of the auto-bumped one
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
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) TAG="$1"; shift ;;
    esac
done
[[ -n "$TAG" && $RELEASE -eq 0 ]] && { echo "A tag only makes sense with -r." >&2; exit 1; }

# The dev build keeps its own bundle id and data, so it installs next to the release app.
# xcode-select may point at CLT without the SwiftUI macros; prefer full Xcode when present.
[[ -d /Applications/Xcode.app ]] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build.sh
APP=build/Cicada.app
ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")
[[ "$ID" == com.wquguru.cicada.dev ]] || { echo "Not a dev build: $ID" >&2; exit 1; }
VERSION=$(tr -d '[:space:]' < VERSION)
NAME="Cicada-Dev-$VERSION-macOS-AppleSilicon"
rm -f build/Cicada-Dev-*.dmg build/Cicada-Dev-*.zip build/checksums-dev.txt

ditto -c -k --keepParent "$APP" "build/$NAME.zip"

# Same installer window as the release DMG: background drawn by the app itself, layout from
# the repo's .DS_Store, staged as "Cicada Dev.app" so it never overwrites the release app.
rm -rf build/dmg-dev && mkdir -p build/dmg-dev/stage/.background build/dmg-dev/mount
"$APP/Contents/MacOS/Cicada" --render-dmg-background build/dmg-dev/background.png 1
"$APP/Contents/MacOS/Cicada" --render-dmg-background build/dmg-dev/background@2x.png 2
tiffutil -cathidpicheck build/dmg-dev/background.png build/dmg-dev/background@2x.png -out build/dmg-dev/background.tiff 2>/dev/null
cp -R "$APP" "build/dmg-dev/stage/Cicada Dev.app"
ln -s /Applications build/dmg-dev/stage/Applications
cp build/dmg-dev/background.tiff build/dmg-dev/stage/.background/background.tiff
[[ -f Resources/dmg/DS_Store ]] && cp Resources/dmg/DS_Store build/dmg-dev/stage/.DS_Store
cp "$APP/Contents/Resources/AppIcon.icns" build/dmg-dev/stage/.VolumeIcon.icns
hdiutil create -quiet -srcfolder build/dmg-dev/stage -volname "Cicada Dev" -fs HFS+ -format UDRW -ov build/dmg-dev/rw.dmg
hdiutil attach -quiet -readwrite -noverify -noautoopen -nobrowse -mountpoint build/dmg-dev/mount build/dmg-dev/rw.dmg
SetFile -a C build/dmg-dev/mount 2>/dev/null || true
hdiutil detach -quiet build/dmg-dev/mount
hdiutil convert -quiet build/dmg-dev/rw.dmg -format UDZO -imagekey zlib-level=9 -ov -o "build/$NAME.dmg"
# Drop the staged copy so Spotlight and Launch Services don't list a third Cicada.app.
rm -rf build/dmg-dev

(cd build && shasum -a 256 "$NAME.dmg" "$NAME.zip" > checksums-dev.txt)
echo "Packaged build/$NAME.dmg, build/$NAME.zip, build/checksums-dev.txt"

[[ $RELEASE -eq 0 ]] && exit 0
command -v gh >/dev/null || { echo "gh not found; upload the files in build/ by hand." >&2; exit 1; }

# Auto tag: v<version>-fork.<n+1>, counting the fork's existing releases.
if [[ -z "$TAG" ]]; then
    LAST=$(gh release list --repo liudicy/cicada --limit 50 --json tagName --jq '.[].tagName' \
        | { grep -E "^v$VERSION-fork\.[0-9]+$" || true; } | sort -t. -k3 -n | tail -1)
    N=$((${LAST##*.} + 1))
    TAG="v$VERSION-fork.$N"
fi
# The tag points at the commit being packaged, so push first.
git push origin main
NOTES=$(cat <<EOF
## 这是什么

个人 fork 的打包版，基于上游 v$VERSION，额外包含：云端语音识别校对（预置小米 MiMo）、纪要编辑与重新整理、删除录音与存储空间页、侧栏「开始听」三入口布局。现场会议、导入录音、自定义模型服务商已并入上游官方实现。

## 安装

拖拽 \`Cicada Dev.app\` 到「应用程序」即可，与上游正式版并存、数据互不影响。个人 ad-hoc 签名，首次打开如被 Gatekeeper 拦截，在终端执行：

\`\`\`sh
xattr -dr com.apple.quarantine "/Applications/Cicada Dev.app"
\`\`\`

仅限 Apple 芯片 Mac，macOS 14.4+。校验值见 checksums-dev.txt。
EOF
)
gh release create "$TAG" --repo liudicy/cicada --prerelease \
    --title "v$VERSION + fork 定制（Cicada Dev）" --notes "$NOTES" \
    "build/$NAME.dmg" "build/$NAME.zip" build/checksums-dev.txt
echo "Published https://github.com/liudicy/cicada/releases/tag/$TAG"
