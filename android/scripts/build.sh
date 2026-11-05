#!/bin/bash
# Builds the Android app on the Mac: build/Cicada-dev.apk (com.wquguru.cicada.dev, with the debug
# receiver), or with RELEASE=1 build/Cicada-<version>-Android.apk signed with the release key
# (scripts/keystore.sh; build/Cicada-unsigned.apk when there is none). Also regenerates the
# onboarding sample from the Mac app's. The launcher icon is vector (res/drawable/ic_launcher_*.xml).
set -euo pipefail
cd "$(dirname "$0")/.."
root=..
# The sample meeting as 16 kHz WAV: the file source and MediaPlayer both read it.
afconvert -f WAVE -d LEI16@16000 -c 1 "$root/Resources/sample/sample.m4a" app/src/main/assets/sample.wav
mkdir -p build
if [ "${RELEASE:-}" = 1 ]; then
  ks="${CICADA_KEYSTORE:-$HOME/.cicada-android/release.jks}"
  if [ -f "$ks" ]; then
    export CICADA_KEYSTORE="$ks"
    [ -n "${CICADA_KEYSTORE_PASSWORD:-}" ] || CICADA_KEYSTORE_PASSWORD=$(security find-generic-password -s cicada-android-release -w)
    export CICADA_KEYSTORE_PASSWORD
    scripts/gradle.sh :app:assembleRelease
    out="build/Cicada-$(tr -d '[:space:]' < "$root/VERSION")-Android.apk"
    cp app/build/outputs/apk/release/app-release.apk "$out"
    scripts/check-release.sh "$out"
    echo "$out ($(du -h "$out" | cut -f1))"
  else
    echo "no release key ($ks): building unsigned; scripts/keystore.sh makes one" >&2
    scripts/gradle.sh :app:assembleRelease
    cp app/build/outputs/apk/release/app-release-unsigned.apk build/Cicada-unsigned.apk && echo "build/Cicada-unsigned.apk ($(du -h build/Cicada-unsigned.apk | cut -f1))"
  fi
else
  scripts/gradle.sh :app:assembleDebug
  cp app/build/outputs/apk/debug/app-debug.apk build/Cicada-dev.apk && echo "build/Cicada-dev.apk ($(du -h build/Cicada-dev.apk | cut -f1))"
fi
