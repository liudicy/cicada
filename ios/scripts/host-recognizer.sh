#!/usr/bin/env bash
# Runs the Mac-side recognizer for the iOS simulator's dev build (ios/tools/host-recognizer):
# the simulator has no working speech models, so the app's audio is recognized here, on device.
#   ios/scripts/host-recognizer.sh ["<device>"...]   (default: every booted simulator)
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=ios/build/host-recognizer
mkdir -p ios/build
xcrun --sdk macosx swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
  Sources/LiveSubs/Recognition.swift Sources/LiveSubs/Languages.swift Sources/LiveSubs/AudioFiles.swift \
  ios/tools/host-recognizer/main.swift -o "$OUT"
# Simulator UDIDs: the booted ones, or the named devices.
if [[ $# -eq 0 ]]; then
  ids=($(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}'))
else
  ids=(); for d in "$@"; do ids+=($(xcrun simctl list devices | grep -F "$d (" | grep -oE '[0-9A-F-]{36}' | head -1)); done
fi
exec "$OUT" "${ids[@]}"
