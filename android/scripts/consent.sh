#!/bin/bash
# Taps through Android's screen-capture consent dialog, as a person does once per listening
# session in 手机里的声音 mode ("Next" first where Android asks one app or the whole screen).
set -euo pipefail
cd "$(dirname "$0")"
TAP_EXACT=1 ./tap.sh "Start now" "Share screen" "Start" "立即开始" "共享屏幕" "开始" "Next" "下一步"
sleep 1
# A second step on some versions.
TAP_EXACT=1 ./tap.sh "Start now" "Share screen" "立即开始" "共享屏幕" 2>/dev/null || true
echo consented
