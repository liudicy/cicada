#!/bin/zsh
# One 同声传译 round on the Mac dev build, scored. The ESP32 says "my" three sentences near the mic
# while the talk key is held (lsctl talkDown / talkUp), one press each. Usage:
#   speak-round.sh <label> [quiet|meeting|silent] [volume 0-100]
#     quiet    the Mac plays nothing
#     meeting  the Mac plays meeting.wav (English, no breaks) from the speakers through every press
#     silent   meeting.wav plays and the key is held, but nobody says anything
# Env: VP (speakVP on|off: the talk key's mic through echo cancellation, default on as in the app), MIC
# (打开麦克风 on|off during the round, default off), SPEAKMIC (the talk key's mic, a name part; default the
# MacBook's: with AirPods as the system input the talk key would hear them), OUT, WORK (as room-round.sh).
# Prints per press what was heard and sent, whether the meeting's English got into what I said,
# what reached the room's lines with MIC on, and the time from release to the translation.
set -e
here=${0:A:h}
repo=${here:h:h:h:h}
label=${1:?label}; mode=${2:-quiet}; vol=${3:-56}
OUT=${OUT:-MacBook Pro Speakers}; VP=${VP:-on}; MIC=${MIC:-off}; SPEAKMIC=${SPEAKMIC:-MacBook Pro Microphone}
WORK=${WORK:-${TMPDIR:-/tmp}/cicada-room-test}
TV=~/workshop/15.experiment/m5-stopwatch/tablevoice/tv.py
LOG=/tmp/livesubs-dev-debug.log
ctl=$repo/tools/lsctl
mkdir -p $WORK
[[ -x $WORK/audio ]] || swiftc -O $here/audio.swift -o $WORK/audio
[[ -f $WORK/me1.wav ]] || python3 $here/clips.py $WORK >/dev/null
[[ $ctl -nt $repo/tools/lsctl.swift ]] || swiftc -O $repo/tools/lsctl.swift -o $ctl

$WORK/audio out "$OUT" >/dev/null
osascript -e "set volume output volume $vol"
$ctl mic:off; $ctl stop; sleep 1
$ctl speakVP:$VP; $ctl speakMic:$SPEAKMIC; $ctl speakOn
from=$(($(wc -l < $LOG) + 1))
if [[ $MIC == on ]]; then $ctl mic:on; else $ctl start:user; fi
sleep 3
[[ $mode == quiet ]] || { afplay $WORK/meeting.wav & }
sleep 2
for i in 1 2 3; do
  rm -f $WORK/voice-$i.m4a
  $ctl speakOut:$WORK/voice-$i.m4a
  $ctl talkDown; sleep 0.4
  if [[ $mode == silent ]]; then sleep 3.2; else python3 $TV play $WORK/me$i.wav >/dev/null; fi
  sleep 0.8; $ctl talkUp
  sleep 8
done
$ctl speakOut:
wait
$ctl mic:off; $ctl stop; sleep 3
session=$(ls -td ~/Library/Application\ Support/LiveSubs\ Dev/Sessions/* | head -1)
tail -n +$from $LOG > $WORK/speak.log
python3 - "$session" "$label" "$WORK" <<'PY'
import json, os, re, sys
session, label, work = sys.argv[1:]
me = ["我们下周三之前可以把测试做完", "价格方面我需要先和财务确认一下", "这个问题我会后发邮件给大家"]
path = session + "/session.json"
lines = json.load(open(path))["lines"] if os.path.exists(path) else []
mine = [l for l in lines if l.get("speaker") == "me"]
room = "".join(l["src"] for l in lines if l.get("via") == "room")
log = open(os.path.join(work, "speak.log")).read()
sent = len(re.findall(r"speak: via=", log))
failed = log.count("translation failed, nothing sent")
times = [(float(a), float(b)) for a, b in re.findall(r"recognize ([\d.]+) s translate ([\d.]+) s", log)]
spoke = re.findall(r"spoke \S+ (\d+) chunks to (.+?) first audio ([\d.]+) s", log)
nothing = log.count("nothing said in the press")
def share(text, ref): return sum(c in text for c in ref) / len(ref)
heard = "".join(l["src"] for l in mine)
english = sum(c.isascii() and c.isalpha() for c in heard)
cells = " ".join("%d%%" % round(100 * share(heard, m)) for m in me)
leak = " ".join("%d%%" % round(100 * share(room, m)) for m in me)
print(f"== {label}: presses=3 sent={sent} failed={failed} me_lines={len(mine)} mine_heard: {cells} english_in_mine={english} "
      f"voiced={len(spoke)} skipped_silent={nothing} in_room_lines: {leak}")
for a, b in times: print(f"   release→text {a:.2f}s, text→translation {b:.2f}s")
for n, dev, first in spoke: print(f"   voice: {n} chunks to {dev}, first audio {first}s after release")
for l in mine: print(f"   me| {l['src'][:60]}  =>  {(l.get('dst') or '')[:70]}")
PY
