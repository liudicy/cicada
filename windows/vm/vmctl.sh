#!/bin/bash
# Host-side helpers for the test VM.
#   vmctl.sh shot <out.png>        # screenshot of the VM's screen (what a viewer of the display sees)
#   vmctl.sh mon <command…>        # one QEMU monitor command (sendkey ret, mouse_move…, system_powerdown)
#   vmctl.sh ssh <powershell…>     # run PowerShell in the VM over SSH
#   vmctl.sh put <local> <remote>  # copy into the VM
#   vmctl.sh run <local.ps1>       # run a script in the VM's desktop session and print its output
#   vmctl.sh g <verb> <args…>      # guest.ps1 in the VM (desk, launch, shot, click, key, front, windows, play)
set -euo pipefail
VM="${VM:-$HOME/VMs/cicada-win11}"
common=(-i "$VM/vm_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
mon() { printf '%s\n' "$*" | nc -U -w 2 "$VM/monitor.sock" >/dev/null; }
case "$1" in
  shot)
    tmp="$VM/shot.ppm"; rm -f "$tmp"; mon "screendump $tmp"
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmp" ] && break; sleep 0.3; done
    sleep 0.3; sips -s format png "$tmp" --out "$2" >/dev/null ;;
  mon) shift; mon "$*" ;;
  ssh) shift; ssh "${common[@]}" -p 2222 tester@127.0.0.1 "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $*" ;;
  g) shift; "$0" ssh "& C:\\cicada-test\\guest.ps1 $*" ;;   # a guest.ps1 verb, e.g. g front
  run) # a local .ps1 in the VM's desktop session: no quoting through ssh and schtasks
    "$0" put "$2" C:/cicada-test/run.ps1 && "$0" g desk "'& C:\\cicada-test\\run.ps1'" ;;
  put) scp -r "${common[@]}" -P 2222 "$2" "tester@127.0.0.1:$3" ;;
  *) echo "usage: vmctl.sh shot|mon|ssh|put" >&2; exit 2 ;;
esac
