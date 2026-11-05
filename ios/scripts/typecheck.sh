#!/usr/bin/env bash
# Typechecks the Mac sources the iOS app shares (ios/shared-sources.txt) together with ios/Sources.
# Without Xcode only the macOS SDK is there: SDK=macosx proves the shared set is self-contained and
# AppKit-free, not that every API exists on iOS. With Xcode, the default checks against the simulator SDK.
set -euo pipefail
cd "$(dirname "$0")/../.."
SDK=${SDK:-iphonesimulator}
if [[ $SDK == iphonesimulator ]]; then TARGET=(-target arm64-apple-ios26.0-simulator); else TARGET=(-target arm64-apple-macos26.0); fi
files=()
while IFS= read -r line; do [[ -z $line || $line == \#* ]] || files+=("$line"); done < ios/shared-sources.txt
shared=("${files[@]}")
while IFS= read -r f; do files+=("$f"); done < <(find ios/Sources -name '*.swift' | sort)
# Frameworks iOS doesn't have: the macOS SDK would accept them, so catch them here.
bad=$(awk '/^#if (os\(macOS\)|canImport\(AppKit\)|!CICADA_IOS)/{g=1} /^#endif/{g=0} !g && /^import (AppKit|CoreAudio|Carbon|SwiftUI|ServiceManagement|IOKit)$/{print FILENAME": "$0}' "${shared[@]}")
if [[ -n $bad ]]; then echo "Mac-only imports in shared sources:"; echo "$bad"; exit 1; fi
xcrun swiftc -typecheck -swift-version 5 -module-name Cicada -sdk "$(xcrun --show-sdk-path --sdk "$SDK")" "${TARGET[@]}" \
  -D CICADA_IOS "${files[@]}"
echo "typecheck ok ($SDK, ${#files[@]} files)"
