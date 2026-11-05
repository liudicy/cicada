#!/bin/bash
# Checks a release APK before it ships: it verifies, and it is not signed with a debug key.
# scripts/check-release.sh build/Cicada-1.1.0-Android.apk
set -euo pipefail
apk=${1:?usage: scripts/check-release.sh <apk>}
sdk="${ANDROID_HOME:-$HOME/.cicada-android/sdk}"
# apksigner is Java: the toolchain from install-sdk.sh on the Mac, setup-java in CI.
[ -n "${JAVA_HOME:-}" ] || export JAVA_HOME="$HOME/.cicada-android/jdk/Contents/Home"
apksigner=$(ls "$sdk"/build-tools/*/apksigner | tail -1)
certs=$("$apksigner" verify --print-certs "$apk")
if grep -q "CN=Android Debug" <<< "$certs"; then echo "$apk is signed with a debug key" >&2; exit 1; fi
grep -m1 "SHA-256 digest" <<< "$certs"
