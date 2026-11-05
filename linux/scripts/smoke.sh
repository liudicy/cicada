#!/bin/bash
# Starts the dev build in the current desktop session (or under xvfb-run in CI), checks that the
# windows open and that the speakers' monitor is heard, then quits. No Ling key needed: a fake one
# lets listening start; Ming's replies fail, which is fine, the capture is what's checked.
#   linux/scripts/smoke.sh            (inside the session: linux/vm/vmctl.sh ssh does that)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
ctl="$here/scripts/cicadactl"; [ -x "$ctl" ] || ctl="$here/bin/cicadactl"  # a checkout, or a build tree with it copied in
export CICADA_HOME="${CICADA_HOME:-$(mktemp -d)}"
[ -f "$CICADA_HOME/ling-api-key" ] || { printf 'sk-smoke-test-key' > "$CICADA_HOME/ling-api-key"; chmod 600 "$CICADA_HOME/ling-api-key"; }
printf '{"onboarded" : true}' > "$CICADA_HOME/settings.json"
"$here/bin/cicada" --dev > "$CICADA_HOME/app.out" 2>&1 &
app=$!
trap 'kill $app 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do "$ctl" state >/dev/null 2>&1 && break; sleep 0.2; done
"$ctl" state | grep -q '"ok":true' || { echo "app didn't start"; cat "$CICADA_HOME/app.out"; exit 1; }
"$ctl" show records >/dev/null
"$ctl" start >/dev/null
# A second of 440 Hz to the default output; the monitor must hear it.
python3 - "$CICADA_HOME/tone.wav" <<'PY'
import math, struct, sys, wave
w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(b"".join(struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * i / 16000))) for i in range(32000))); w.close()
PY
sleep 1
(command -v pw-play >/dev/null && pw-play "$CICADA_HOME/tone.wav") || paplay "$CICADA_HOME/tone.wav"
sleep 1
state="$("$ctl" state)"
echo "$state"
"$ctl" windows
python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["listening"], "not listening"; assert s["peak"] > 0.05, "monitor heard nothing (peak %s)" % s["peak"]' "$state"
# SMOKE_VOICES=1 (CI, on the installed tarball): 说话人识别 must load, i.e. the shipped library links here.
[ -z "${SMOKE_VOICES:-}" ] || python3 -c 'import json,sys; assert json.loads(sys.argv[1])["speakers"]["available"], "voiceprint library did not load"' "$state"
"$ctl" stop >/dev/null
"$ctl" quit >/dev/null || true
wait $app 2>/dev/null || true
echo "smoke: ok"
