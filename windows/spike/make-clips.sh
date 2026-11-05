#!/bin/bash
# Regenerates windows/spike/clips/{en,zh,ja}.wav from the .txt beside them: one `say` call per
# sentence, 0.8 s of silence between sentences so the pauses look like a meeting. macOS only.
set -euo pipefail
cd "$(dirname "$0")/clips"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for lang in en zh ja; do
  case $lang in en) v=Samantha;; zh) v=Tingting;; ja) v=Kyoko;; esac
  parts=(); i=0
  while IFS= read -r line; do
    i=$((i+1)); say -v "$v" -o "$T/$lang-$i.aiff" "$line"
    afconvert -f WAVE -d LEI16@16000 -c 1 "$T/$lang-$i.aiff" "$T/$lang-$i.wav"; parts+=("$T/$lang-$i.wav")
  done < "$lang.txt"
  python3 - "$lang.wav" "${parts[@]}" <<'PY'
import sys, wave
out, parts = sys.argv[1], sys.argv[2:]
pcm = b""
for p in parts:
    with wave.open(p) as f: pcm += f.readframes(f.getnframes()) + b"\0\0" * int(16000 * 0.8)
with wave.open(out, "wb") as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(16000); f.writeframes(pcm)
PY
done
