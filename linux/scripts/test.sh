#!/bin/bash
# The voiceprint library, unit tests for the engines (no network, no GTK), the translation check, and a syntax check of the app.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
# The voiceprint library, so its test checks it against the Mac's model (needs a C compiler).
native/build.sh >/dev/null
python3 -m unittest discover -s tests -q
python3 scripts/strings.py
python3 -m py_compile cicada/app/*.py cicada/core/*.py cli.py
echo "linux: ok"
