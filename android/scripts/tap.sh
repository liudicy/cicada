#!/bin/bash
# Taps the first on-screen element whose text (or description) is one of the given labels,
# waiting up to 10 s for it: scripts/tap.sh "开始听" "Start listening". For driving the real UI in
# tests (system dialogs too). Exits 1 if none shows up. TAP_EXACT=0 matches substrings.
set -euo pipefail
adb="$HOME/.cicada-android/sdk/platform-tools/adb"
xml=$(mktemp); trap 'rm -f "$xml"' EXIT
for _ in $(seq 1 10); do
  "$adb" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 || true
  "$adb" shell cat /sdcard/ui.xml > "$xml" 2>/dev/null || true
  hit=$(python3 - "$xml" "${TAP_EXACT:-1}" "$@" <<'PY'
import re, sys, html
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
exact = sys.argv[2] == "1"
nodes = re.findall(r'<node [^>]*>', xml)
for label in sys.argv[3:]:
    for n in nodes:
        t = html.unescape((re.search(r' text="([^"]*)"', n) or [None, ""])[1])
        d = html.unescape((re.search(r'content-desc="([^"]*)"', n) or [None, ""])[1])
        if (exact and label in (t, d)) or (not exact and (label in t or label in d)):
            x1, y1, x2, y2 = map(int, re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n).groups())
            print((x1 + x2) // 2, (y1 + y2) // 2); sys.exit()
PY
)
  if [ -n "$hit" ]; then "$adb" shell input tap $hit; exit 0; fi
  sleep 1
done
echo "not on screen: $*" >&2; exit 1
