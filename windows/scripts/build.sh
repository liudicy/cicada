#!/bin/bash
# Builds the Windows app on the Mac: build/Cicada-win-x64/ and build/Cicada-win-arm64/, each a
# self-contained Cicada.exe with everything inside it. RELEASE=1 for a release build, which also
# writes build/Cicada-Setup.exe and Cicada-Setup-arm64.exe (the same exe, for people to download);
# else a dev build, which keeps its records under "Cicada Dev" and opens the debug pipe.
set -euo pipefail
cd "$(dirname "$0")/.."
root=..
mkdir -p build/icon src/Cicada/Assets

# The icon (committed, regenerated here): the Mac app's 256 px icon at the sizes Windows asks for, PNGs inside one .ico.
for s in 16 24 32 48 64 256; do sips -z $s $s "$root/docs/icon.png" --out "build/icon/$s.png" >/dev/null; done
python3 - build/icon <<'PY'
import struct, sys, os
d = sys.argv[1]; sizes = [16, 24, 32, 48, 64, 256]
pngs = [open(os.path.join(d, f"{s}.png"), "rb").read() for s in sizes]
out = struct.pack("<HHH", 0, 1, len(sizes)); offset = 6 + 16 * len(sizes)
for s, p in zip(sizes, pngs):
    out += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(p), offset); offset += len(p)
open(os.path.join(d, "..", "..", "src", "Cicada", "Assets", "cicada.ico"), "wb").write(out + b"".join(pngs))
PY

# The onboarding sample as 16 kHz WAV: SoundPlayer and the file source both read WAV only.
# afconvert writes WAVE_FORMAT_EXTENSIBLE plus a FLLR chunk, which SoundPlayer refuses
# (InvalidOperationException), so rewrite it as a plain PCM WAV.
afconvert -f WAVE -d LEI16@16000 -c 1 "$root/Resources/sample/sample.m4a" build/icon/sample.wav
python3 - build/icon/sample.wav src/Cicada/Assets/sample.wav <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read(); i = 12; pcm = b""
while i < len(d):
    n = int.from_bytes(d[i+4:i+8], "little")
    if d[i:i+4] == b"data": pcm = d[i+8:i+8+n]
    i += 8 + n + (n & 1)
fmt = struct.pack("<HHIIHH", 1, 1, 16000, 32000, 2, 16)
open(sys.argv[2], "wb").write(b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(pcm)) + b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(pcm)) + pcm)
PY

config=Debug; [ "${RELEASE:-}" = 1 ] && config=Release
for rid in win-x64 win-arm64; do
  out="build/Cicada-$rid"
  rm -rf "$out"
  scripts/dotnet.sh publish src/Cicada -c "$config" -r "$rid" -o "$out" -p:DebugType=embedded -v quiet -nologo 2>&1 | grep -E ' error |warning CS' | sort -u || true
  [ -f "$out/Cicada.exe" ] || { echo "build failed for $rid" >&2; exit 1; }
  # The exe is the whole app (the UI text and the sample are inside it): Cicada-Setup.exe is a copy.
  [ "$(ls "$out" | grep -v '^Cicada.exe$' | grep -v '^test$' | grep -v '^Cicada Dev.cmd$' || true)" = "" ] || { echo "unexpected files beside Cicada.exe in $out: $(ls "$out")" >&2; exit 1; }
  if [ "$config" = Release ]; then
    setup=build/Cicada-Setup.exe; [ "$rid" = win-arm64 ] && setup=build/Cicada-Setup-arm64.exe
    cp "$out/Cicada.exe" "$setup"; echo "$setup"
  fi
  if [ "$config" = Debug ]; then
    printf '@echo off\r\nstart "" "%%~dp0Cicada.exe" --dev\r\n' > "$out/Cicada Dev.cmd"
    # Everything the VM test needs in the one folder: the capture probe, the control script and the clips.
    mkdir -p "$out/test"
    scripts/dotnet.sh publish spike/LoopbackProbe -c Release -r "$rid" -o "$out/test" -p:DebugType=none -v quiet -nologo >/dev/null
    cp scripts/cicadactl.ps1 "$out/test/"
    cp spike/clips/*.wav "$out/test/" 2>/dev/null || echo "no clips: run spike/make-clips.sh" >&2
  fi
  echo "$out/Cicada.exe ($(du -h "$out/Cicada.exe" | cut -f1))"
done
