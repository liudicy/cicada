#!/bin/bash
# Builds the installable tree build/cicada-linux/ and build/cicada-linux-<version>.tar.gz: the Python
# package, the strings tables (the Mac's Localizable.strings plus Linux.strings), the sample meeting
# as 16 kHz WAV, the menu entry, the icon and install.sh. Runs on the Mac or on Linux.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root="$(dirname "$here")"
version="$(tr -d '[:space:]' < "$root/VERSION")"
out="$here/build/cicada-linux"
rm -rf "$out" && mkdir -p "$out/lproj"
rsync -a --exclude __pycache__ "$here/cicada" "$out/"
for lang in zh-Hans en ja ko; do
  mkdir -p "$out/lproj/$lang.lproj"
  cp "$root/Resources/$lang.lproj/Localizable.strings" "$out/lproj/$lang.lproj/"
  [ -f "$here/strings/$lang.lproj/Linux.strings" ] && cp "$here/strings/$lang.lproj/Linux.strings" "$out/lproj/$lang.lproj/"
done
mkdir -p "$out/bin" && cp "$here/bin/cicada" "$out/bin/"
# 说话人识别: the voiceprint weights and libcicada-voice-<arch>.so for each architecture built so far
# (native/out: CI builds x86_64 and aarch64 on Ubuntu 22.04; on Linux this machine's is built here).
mkdir -p "$out/models" "$out/lib" && cp "$here/models/voiceprint.bin" "$out/models/"
if [ "$(uname)" = Linux ] && [ ! -f "$here/native/out/libcicada-voice-$(uname -m).so" ] && command -v "${CC:-gcc}" >/dev/null; then
  "$here/native/build.sh"
fi
cp "$here"/native/out/libcicada-voice-*.so "$out/lib/" 2>/dev/null || echo "note: no voiceprint library in this build (说话人识别 unavailable)" >&2
cp "$root/VERSION" "$out/"   # read by cicada/__init__.py
# The sample meeting as 16 kHz mono WAV: the file source reads WAV only, and Linux may lack an AAC decoder.
sample="$root/Resources/sample/sample.m4a"
if command -v afconvert >/dev/null; then afconvert -f WAVE -d LEI16@16000 -c 1 "$sample" "$out/sample.wav"
elif command -v ffmpeg >/dev/null; then ffmpeg -loglevel error -y -i "$sample" -ac 1 -ar 16000 -c:a pcm_s16le "$out/sample.wav"
else echo "warning: no afconvert or ffmpeg, the build has no sample meeting" >&2; fi
cp "$here/packaging/com.wquguru.cicada.desktop" "$here/packaging/install.sh" "$out/"
cp "$root/site/icon.svg" "$out/cicada.svg"
tar -C "$here/build" -czf "$here/build/cicada-linux-$version.tar.gz" cicada-linux
echo "build/cicada-linux-$version.tar.gz"
