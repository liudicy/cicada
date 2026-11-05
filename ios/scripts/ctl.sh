#!/usr/bin/env bash
# Sends debug commands to the dev build in a simulator (ios/Sources/Cicada/Debug.swift), the iOS
# counterpart of tools/lsctl:  ios/scripts/ctl.sh [-d "<device>"] <cmd> [<cmd>...]
set -euo pipefail
DEVICE=booted
if [[ ${1:-} == -d ]]; then DEVICE=$2; shift 2; fi
DATA=$(xcrun simctl get_app_container "$DEVICE" com.wquguru.cicada.dev data)
printf '%s\n' "$@" >> "$DATA/Library/Caches/debug-command"
xcrun simctl spawn "$DEVICE" notifyutil -p com.wquguru.cicada.debug
