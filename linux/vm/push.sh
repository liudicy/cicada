#!/bin/bash
# Copies the built tree (linux/scripts/build.sh) into the test VM as ~/cicada-linux, with the dev
# tools (cicadactl, smoke.sh, the focus test) in its bin/. Stops a running dev build first.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
VM="${VM:-$HOME/VMs/cicada-ubuntu}"
o=(-q -i "$VM/vm_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ControlMaster=auto -o ControlPath="$VM/ssh.sock" -o ControlPersist=600)
ssh "${o[@]}" -p 2223 cicada@127.0.0.1 'pkill -f "python3 -m cicada[.]app" || true; rm -rf ~/cicada-linux'
scp "${o[@]}" -P 2223 -r "$here/build/cicada-linux" cicada@127.0.0.1:
scp "${o[@]}" -P 2223 "$here/scripts/cicadactl" "$here/scripts/smoke.sh" "$here/vm/focus_probe.py" "$here/vm/fullscreen_probe.py" "$here/vm/set_scale.py" "$here/vm/long_session.py" "$here/vm/click.py" "$here/vm/focus_test.sh" cicada@127.0.0.1:cicada-linux/bin/
# The voiceprint library for the VM's architecture (the Mac can't link Linux binaries): built there.
scp "${o[@]}" -P 2223 -q "$here/native/voiceprint.c" "$here/native/build.sh" cicada@127.0.0.1:cicada-linux/lib/
ssh "${o[@]}" -p 2223 cicada@127.0.0.1 'cd ~/cicada-linux/lib && command -v gcc >/dev/null && bash build.sh . && rm -f voiceprint.c build.sh || echo "no gcc in the VM: sudo apt install build-essential"'
echo "pushed to ~/cicada-linux"
