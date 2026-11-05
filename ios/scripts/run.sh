#!/usr/bin/env bash
# Installs ios/build/Cicada.app into a simulator and launches it.
#   ios/scripts/run.sh [device name] [--seed <session folder>...]
# --seed copies Mac meeting folders (…/LiveSubs Dev/Sessions/<id>) into the app first.
# Then drive it: xcrun simctl openurl "<device>" 'cicada-dev://debug?cmd=…' (commands: ios/Sources/Cicada/Debug.swift).
set -euo pipefail
cd "$(dirname "$0")/../.."
DEVICE=${1:-"iPhone 18 Pro"}; shift || true
ID=com.wquguru.cicada.dev

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl terminate "$DEVICE" "$ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" ios/build/Cicada.app
if [[ "${1:-}" == --seed ]]; then
  shift
  DATA=$(xcrun simctl get_app_container "$DEVICE" "$ID" data)
  mkdir -p "$DATA/Library/Application Support/LiveSubs Dev/Sessions"
  for s in "$@"; do cp -R "$s" "$DATA/Library/Application Support/LiveSubs Dev/Sessions/"; done
fi
xcrun simctl launch "$DEVICE" "$ID" >/dev/null
echo "Running on $DEVICE; log: $(xcrun simctl get_app_container "$DEVICE" "$ID" data)/Library/Caches/livesubs-dev-debug.log"
