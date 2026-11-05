#!/usr/bin/env bash
# Builds ios/build/Cicada.app for the iOS simulator: the shared Mac sources (ios/shared-sources.txt)
# and ios/Sources in one module, bundled by hand like the Mac's scripts/build.sh (no .xcodeproj).
# Without RELEASE=1 it is a dev build: "Cicada Dev", bundle id com.wquguru.cicada.dev, cicada-dev:// commands.
set -euo pipefail
cd "$(dirname "$0")/../.."

SDK=iphonesimulator
TARGET=arm64-apple-ios26.0-simulator
APP=ios/build/Cicada.app
rm -rf "$APP"
mkdir -p "$APP"

files=()
while IFS= read -r line; do [[ -z $line || $line == \#* ]] || files+=("$line"); done < ios/shared-sources.txt
while IFS= read -r f; do files+=("$f"); done < <(find ios/Sources -name '*.swift' | sort)

# STRINGS_OUT=<dir>: also write the UI text keys there (scripts/strings.py).
extra=()
[[ -n "${STRINGS_OUT:-}" ]] && extra=(-emit-localized-strings -emit-localized-strings-path "$STRINGS_OUT")
xcrun --sdk "$SDK" swiftc -O -swift-version 5 -parse-as-library -module-name Cicada \
  -target "$TARGET" -sdk "$(xcrun --show-sdk-path --sdk "$SDK")" -D CICADA_IOS \
  "${extra[@]+"${extra[@]}"}" "${files[@]}" -o "$APP/Cicada"

cp ios/Resources/Info.plist "$APP/Info.plist"
# UI text is the Mac's: the Chinese source is the key, the other languages translate it.
for d in Resources/*.lproj; do
  mkdir -p "$APP/$(basename "$d")"
  cp "$d/Localizable.strings" "$APP/$(basename "$d")/" 2>/dev/null || true
done
cp -R "$APP/zh-Hans.lproj" "$APP/zh-Hant.lproj"
cp Resources/sample/sample.m4a "$APP/"
# 说话人识别's voiceprint model, compiled on first use as on the Mac (SpeakerID.swift).
cp -R Resources/models/SpeakerEmbedding.mlpackage "$APP/"
# The logo on the 听会议室 card: the Mac's own icon renderer (Sources/LiveSubsIcon), not a fourth
# copy of the geometry. It is a host tool, built once.
ICON_TOOL=.build/release/LiveSubsIcon
[[ -x $ICON_TOOL ]] || swift build -c release --product LiveSubsIcon >/dev/null
ICONS=$(mktemp -d)
"$ICON_TOOL" "$ICONS/logo.iconset" >/dev/null
cp "$ICONS/logo.iconset/icon_128x128@2x.png" "$APP/logo.png"
rm -rf "$ICONS"

# The Live Activity (lock screen, Dynamic Island): a WidgetKit extension in PlugIns. The attributes
# type is compiled into both, so the app and the extension agree on it. Linked like Xcode links an
# app extension: entered through _NSExtensionMain, which runs the @main WidgetBundle on the main
# queue (the plain Swift entry point dies in libdispatch before the bundle loads).
APPEX="$APP/PlugIns/CicadaLive.appex"
mkdir -p "$APPEX"
xcrun --sdk "$SDK" swiftc -O -swift-version 5 -parse-as-library -application-extension -module-name CicadaLive \
  -target "$TARGET" -sdk "$(xcrun --show-sdk-path --sdk "$SDK")" \
  -Xlinker -e -Xlinker _NSExtensionMain \
  ios/LiveActivity/*.swift ios/Sources/Cicada/ListenActivity.swift -o "$APPEX/CicadaLive"
cp ios/LiveActivity/Info.plist "$APPEX/Info.plist"
cp "$APP/logo.png" "$APPEX/"
for d in "$APP"/*.lproj; do cp -R "$d" "$APPEX/"; done

PLIST="$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(tr -d '[:space:]' < VERSION)" "$PLIST"
if [[ "${RELEASE:-}" != 1 ]]; then
  STAMP="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo local) @ $(git rev-parse --short HEAD 2>/dev/null || echo none)"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.wquguru.cicada.dev" \
    -c "Set :CFBundleName Cicada Dev" -c "Set :CFBundleDisplayName Cicada Dev" \
    -c "Add :LiveSubsDev string $STAMP" \
    -c "Add :CFBundleURLTypes array" -c "Add :CFBundleURLTypes:0 dict" \
    -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string cicada-dev" \
    "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.wquguru.cicada.dev.live" "$APPEX/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(tr -d '[:space:]' < VERSION)" "$APPEX/Info.plist"
codesign --force --sign - "$APPEX" 2>/dev/null
codesign --force --sign - "$APP" 2>/dev/null
echo "Built $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST"))"
