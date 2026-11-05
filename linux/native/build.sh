#!/bin/bash
# Builds the voiceprint library (voiceprint.c) for this machine into $1 (default native/out):
# libcicada-voice-<arch>.so on Linux, libcicada-voice.dylib on the Mac (unit tests only).
# Release builds come from CI on Ubuntu 22.04, so the .so loads on 22.04 and 24.04 alike.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/out}"
mkdir -p "$out"
if [ "$(uname)" = Darwin ]; then
  /usr/bin/clang -O3 -Wall -Wextra -shared -fPIC -o "$out/libcicada-voice.dylib" "$here/voiceprint.c"
else
  ${CC:-gcc} -O3 -Wall -Wextra -shared -fPIC -pthread -o "$out/libcicada-voice-$(uname -m).so" "$here/voiceprint.c" -lm
fi
