#!/bin/zsh
# One room-test round on the Mac dev build, scored. Usage:
#   room-round.sh <label> [mac|music|none] [volume 0-100]
# Env: OUT (output device name part, default "MacBook Pro Speakers"; "BlackHole" stands in for
# headphones), ECHO (roomEcho bypass|on|off, default bypass as in the app), GATE (roomGate on|off, default on),
# TABLE (on|off: play table.wav on the ESP32, default on), WORK (clips and tools, default
# $TMPDIR/cicada-room-test).
# Prints: mac/room line counts, echoes dropped, English room lines (echo that got through), and
# for each table sentence gap|over and the share of its characters found in the room lines.
set -e
here=${0:A:h}
repo=${here:h:h:h:h}
label=${1:?label}; play=${2:-mac}; vol=${3:-56}
OUT=${OUT:-MacBook Pro Speakers}; ECHO=${ECHO:-bypass}; GATE=${GATE:-on}; TABLE=${TABLE:-on}
WORK=${WORK:-${TMPDIR:-/tmp}/cicada-room-test}
TV=~/workshop/15.experiment/m5-stopwatch/tablevoice/tv.py
LOG=/tmp/livesubs-dev-debug.log
ctl=$repo/tools/lsctl
mkdir -p $WORK
[[ -x $WORK/audio ]] || swiftc -O $here/audio.swift -o $WORK/audio
[[ -f $WORK/table.wav ]] || python3 $here/clips.py $WORK >/dev/null
[[ $ctl -nt $repo/tools/lsctl.swift ]] || swiftc -O $repo/tools/lsctl.swift -o $ctl

$WORK/audio out "$OUT" >/dev/null
osascript -e "set volume output volume $vol"
$ctl roomEcho:$ECHO; $ctl roomGate:$GATE; $ctl mic:off; $ctl stop; sleep 1
from=$(($(wc -l < $LOG) + 1))
$ctl mic:on; sleep 2
t0=$(python3 -c "import time; print(int(time.time()) + 6)")
at=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($t0, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
[[ $TABLE == on ]] && python3 $TV play $WORK/table.wav --at $at > $WORK/tv.out 2>&1 &
python3 -c "import time; time.sleep(max(0, $t0 - time.time()))"
if [[ $play == none ]]; then sleep 52; else afplay $WORK/$play.wav; fi
wait; sleep 8
$ctl hybridState; sleep 1
$ctl mic:off; $ctl stop; sleep 3
session=$(ls -td ~/Library/Application\ Support/LiveSubs\ Dev/Sessions/* | head -1)
tail -n +$from $LOG > $WORK/round.log
python3 - "$session" "$label" "$WORK/round.log" <<'PY'
import json, re, sys
session, label, log = sys.argv[1:]
table = ["我同意这个数字", "等一下企业版具体涨了多少", "设计那个岗位很急", "好的没问题", "导出功能我们下周排期", "周四之前我会回复"]
over = [False, True, False, True, True, False]
lines = json.load(open(session + "/session.json"))["lines"]
room = [l["src"] for l in lines if l.get("via") == "room"]
mac = [l for l in lines if l.get("via") != "room"]
text = "".join(room)
english = [r for r in room if sum(c.isascii() and c.isalpha() for c in r) > 5]
log = open(log).read()
dropped = log.count("dropped as an echo")
state = re.findall(r"hybrid state .*", log)
echo = re.search(r"echo=(\S+) \[([^]]*)\]", state[-1]) if state else None
cells = " ".join(("抢" if o else "空") + "%d%%" % round(100 * sum(c in text for c in t) / len(t)) for t, o in zip(table, over))
print(f"== {label}: mac={len(mac)} room={len(room)} echo_dropped={dropped} english_room={len(english)} table: {cells}")
if echo: print(f"   echo={echo.group(1)} [{echo.group(2)}]")
for r in room: print("   room|", r[:90])
PY
