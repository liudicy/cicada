#!/bin/bash
# Gradle with the toolchain from install-sdk.sh (~/.cicada-android), run from android/. Java ignores
# http(s)_proxy, so a proxy in the environment is handed to Gradle as system properties.
set -euo pipefail
D="$HOME/.cicada-android"
export JAVA_HOME="$D/jdk/Contents/Home" ANDROID_HOME="$D/sdk"
cd "$(dirname "$0")/.."
props=()
if [ -n "${https_proxy:-${HTTPS_PROXY:-}}" ]; then
  p="${https_proxy:-$HTTPS_PROXY}"; p="${p#*://}"; p="${p%/}"; host="${p%:*}"; port="${p##*:}"
  props=(-Dhttps.proxyHost="$host" -Dhttps.proxyPort="$port" -Dhttp.proxyHost="$host" -Dhttp.proxyPort="$port"
         "-Dhttp.nonProxyHosts=localhost|127.0.0.1")
fi
exec "$D/gradle/bin/gradle" --console=plain -q ${props[@]+"${props[@]}"} "$@"
