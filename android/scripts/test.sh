#!/bin/bash
# Unit tests for the Android engines; runs on the Mac (no network, no emulator).
set -euo pipefail
exec "$(dirname "$0")/cli.sh" test
