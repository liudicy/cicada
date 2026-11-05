#!/bin/bash
# Quits Cicada in the test VM and copies in fresh builds (run scripts/build.sh first).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
"$here/vmctl.sh" ssh 'Get-Process Cicada -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 1; Remove-Item C:\cicada-test\Cicada-win-arm64, C:\cicada-test\Cicada-win-x64 -Recurse -Force -ErrorAction SilentlyContinue; exit 0'
for rid in win-arm64 win-x64; do "$here/vmctl.sh" put "$here/../build/Cicada-$rid" C:/cicada-test/; done
"$here/vmctl.sh" put "$here/guest.ps1" C:/cicada-test/
echo deployed
