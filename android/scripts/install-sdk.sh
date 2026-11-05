#!/bin/bash
# One-time toolchain for the Android app, all under ~/.cicada-android (no sudo, nothing system-wide):
# a JDK 21, Gradle, the Android SDK (platform, build tools, emulator) and an arm64 system image for
# the test emulator. Versions are pinned and every download is checked against its published
# checksum before it is unpacked. Re-running skips what is already there. --old also makes
# `cicada29`, an Android 10 emulator (the oldest Android the app supports).
set -euo pipefail
D="$HOME/.cicada-android"; mkdir -p "$D"; cd "$D"
JDK=21.0.13_9; JDK_TAG="jdk-21.0.13%2B9"
JDK_SHA_ARM=bf036b35b071bfb2f54f2c0af8ee8d88afa95ee6eb3dce02c0f94cfc2524d04a
JDK_SHA_X64=9aa1d1c17ae5467a022679e7e0af5c00797d94ac462ed1a46f4db07a8a34a6dd
GRADLE=9.8.2; GRADLE_SHA=21bd5da2de49b642904077f38c0efdc7778e92b3ed0889392dca61b97e389607
CLT=15641748; CLT_SHA1=b62a5d8cf63ded173b47be867be4ee058ceda6df
API=36; BUILD_TOOLS=36.0.0

# fetch <url> <file> <sha256|sha1:…>: download, then refuse anything that doesn't match.
fetch() {
  curl -fsSL "$1" -o "$2.part"
  local want="$3" got
  if [[ "$want" == sha1:* ]]; then want="${want#sha1:}"; got=$(shasum -a 1 "$2.part" | cut -d' ' -f1)
  else got=$(shasum -a 256 "$2.part" | cut -d' ' -f1); fi
  if [ "$got" != "$want" ]; then rm -f "$2.part"; echo "checksum mismatch for $1" >&2; exit 1; fi
  mv "$2.part" "$2"
}

if [ "$(uname -m)" = arm64 ]; then jarch=aarch64; jsha=$JDK_SHA_ARM; else jarch=x64; jsha=$JDK_SHA_X64; fi
if [ ! -x jdk/Contents/Home/bin/java ]; then
  fetch "https://github.com/adoptium/temurin21-binaries/releases/download/$JDK_TAG/OpenJDK21U-jdk_${jarch}_mac_hotspot_$JDK.tar.gz" jdk.tgz "$jsha"
  rm -rf jdk-x && mkdir jdk-x && tar -xzf jdk.tgz -C jdk-x && mv jdk-x/*/ jdk && rm -rf jdk-x jdk.tgz
fi
if [ ! -x "gradle-$GRADLE/bin/gradle" ]; then
  fetch "https://services.gradle.org/distributions/gradle-$GRADLE-bin.zip" gradle.zip "$GRADLE_SHA"
  unzip -q gradle.zip && rm gradle.zip
fi
ln -sfn "gradle-$GRADLE" gradle
export JAVA_HOME="$D/jdk/Contents/Home" ANDROID_HOME="$D/sdk"
if [ ! -x sdk/cmdline-tools/latest/bin/sdkmanager ]; then
  fetch "https://dl.google.com/android/repository/commandlinetools-mac-${CLT}_latest.zip" clt.zip "sha1:$CLT_SHA1"
  mkdir -p sdk/cmdline-tools && unzip -q clt.zip -d sdk/cmdline-tools && mv sdk/cmdline-tools/cmdline-tools sdk/cmdline-tools/latest && rm clt.zip
fi
# sdkmanager checks its own packages' checksums.
sm=sdk/cmdline-tools/latest/bin/sdkmanager; avd=sdk/cmdline-tools/latest/bin/avdmanager
yes | "$sm" --licenses >/dev/null || true
images=("system-images;android-$API;google_apis;arm64-v8a")
[ "${1:-}" = --old ] && images+=("system-images;android-29;google_apis;arm64-v8a")
"$sm" "platform-tools" "platforms;android-$API" "build-tools;$BUILD_TOOLS" "emulator" "${images[@]}" >/dev/null
"$avd" list avd -c | grep -qx cicada || echo no | "$avd" create avd -n cicada -k "${images[0]}" -d pixel_7 >/dev/null
if [ "${1:-}" = --old ] && ! "$avd" list avd -c | grep -qx cicada29; then
  echo no | "$avd" create avd -n cicada29 -k "${images[1]}" -d pixel_4 >/dev/null
fi
echo "ok: $D"
