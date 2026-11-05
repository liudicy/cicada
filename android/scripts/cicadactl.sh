#!/bin/bash
# Drives the dev build in the emulator or a phone (adb): scripts/cicadactl.sh state | start mic |
# feed en.wav | sample | view subtitles | capture on | stop | … (see DebugReceiver.kt). Prints the
# app's one-line JSON reply. `push <file>` copies a file into the app's files/ for feed and import;
# `key` copies the Mac app's Ling key in (never printed); `log` prints the debug log.
set -euo pipefail
adb="$HOME/.cicada-android/sdk/platform-tools/adb"
pkg=com.wquguru.cicada.dev
case "${1:-state}" in
  push)
    "$adb" push "$2" /data/local/tmp/cicada-push >/dev/null
    "$adb" shell "run-as $pkg sh -c 'cat /data/local/tmp/cicada-push > files/$(basename "$2")'; rm /data/local/tmp/cicada-push"
    echo "files/$(basename "$2")"; exit 0 ;;
  key)
    f="${CICADA_KEY_FILE:-$HOME/Library/Application Support/LiveSubs Dev/ling-api-key}"
    [ -f "$f" ] || f="$HOME/Library/Application Support/LiveSubs/ling-api-key"
    "$adb" shell "run-as $pkg sh -c 'mkdir -p files && cat > files/ling-api-key && chmod 600 files/ling-api-key'" < "$f"
    set -- key reload ;;
  log) exec "$adb" shell "run-as $pkg cat cache/cicada-dev-debug.log" ;;
esac
send() { "$adb" shell am broadcast -a com.wquguru.cicada.dev.DEBUG -p "$pkg" -f 0x20 --es cmd "'$*'" 2>&1; }
out=$(send "$@"); printf "%s" "$out" | grep -q "data=" || { sleep 2; out=$(send "$@"); }
data=$(printf '%s' "$out" | sed -n 's/.*data="\(.*\)"$/\1/p' | tr -d '\r')
[ -n "$data" ] && echo "$data" || { echo "$out" >&2; exit 1; }
