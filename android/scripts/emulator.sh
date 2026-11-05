#!/bin/bash
# Boots the `cicada` emulator (AVD=cicada29 for Android 10; made by install-sdk.sh) and waits until Android is up. Network goes
# through the Mac's proxy when one is set, so Google translation works too. --wipe starts clean.
set -euo pipefail
D="$HOME/.cicada-android"; S="$D/sdk"; adb="$S/platform-tools/adb"
AVD="${AVD:-cicada}"
running=$("$adb" emu avd name 2>/dev/null | head -1 | tr -d '\r' || true)
if [ "$running" = "$AVD" ]; then echo "already running"; exit 0; fi
if [ -n "$running" ]; then echo "emulator $running is running: stop it first (adb emu kill)" >&2; exit 1; fi
args=(-avd "$AVD" -no-snapshot-save -no-boot-anim -gpu swiftshader_indirect)
[ "${1:-}" = --wipe ] && args+=(-wipe-data)
p="${https_proxy:-${HTTPS_PROXY:-}}"; [ -n "$p" ] && args+=(-http-proxy "${p%/}")
[ -n "${HEADLESS:-}" ] && args+=(-no-window)
nohup "$S/emulator/emulator" "${args[@]}" > "${TMPDIR:-/tmp}/cicada-emulator.log" 2>&1 &
"$adb" wait-for-device
until [ "$("$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 2; done
"$adb" shell settings put global window_animation_scale 0
"$adb" shell settings put global transition_animation_scale 0
"$adb" shell settings put global animator_duration_scale 0
echo "booted"
