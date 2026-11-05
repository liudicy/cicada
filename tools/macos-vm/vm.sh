#!/bin/bash
# The macOS 14 test VM (tart, Apple silicon). Everything lives in ~/VMs: TART_HOME=~/VMs/tart, the
# SSH key ~/VMs/mac_key, the shared folder ~/VMs/share (/Volumes/My Shared Files/share in the VM).
#   tools/macos-vm/vm.sh setup     # once: pull the image (~18 GB), clone it, install the key and helpers
#   tools/macos-vm/vm.sh start     # boot it (window on screen), tunnel the host proxy into it
#   tools/macos-vm/vm.sh deploy    # install build/Cicada.app (a dev build) in the VM and launch it
#   tools/macos-vm/vm.sh listen <clip in ~/VMs/share> [wait]   # start listening, play the clip there, print the log
#   tools/macos-vm/vm.sh ssh [command]
#   tools/macos-vm/vm.sh stop
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
export TART_HOME="${TART_HOME:-$HOME/VMs/tart}"
TART="${TART:-$HOME/VMs/tools/tart/tart.app/Contents/MacOS/tart}"
NAME=cicada-macos14
IMAGE=ghcr.io/cirruslabs/macos-sonoma-vanilla:14.4.1   # ships macOS 14.5; user admin / admin
KEY="$HOME/VMs/mac_key"
SHARE="$HOME/VMs/share"
ip() { "$TART" ip "$NAME"; }
run() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "admin@$(ip)" "$@"; }

case "${1:-}" in
setup)
  [ -x "$TART" ] || { echo "Get tart from https://github.com/openai/tart/releases (check the SHA-256 in its checksums file) into ~/VMs/tools/tart"; exit 1; }
  "$TART" pull "$IMAGE"
  "$TART" clone "$IMAGE" "$NAME"
  mkdir -p "$SHARE/tools"; [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -f "$KEY"
  "$0" start
  expect -c "set timeout 30
    spawn ssh-copy-id -i $KEY.pub -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$(ip)
    expect { -re {[Pp]assword:} { send \"admin\r\"; exp_continue } eof }" >/dev/null
  # Helpers built for 14.4, and clicks from SSH allowed (SIP is off in this image).
  for t in lsctl mouse winall key; do swiftc -O -target arm64-apple-macos14.4 "$repo/tools/$t.swift" -o "$SHARE/tools/$t"; done
  run 'mkdir -p ~/bin && cp "/Volumes/My Shared Files/share/tools/"* ~/bin/
    for c in /usr/libexec/sshd-keygen-wrapper /Users/admin/bin/mouse; do for s in kTCCServiceAccessibility kTCCServicePostEvent; do
      sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "insert or replace into access (service,client,client_type,auth_value,auth_reason,auth_version,flags) values (\"$s\",\"$c\",1,2,4,1,0)"; done; done
    sudo killall tccd || true
    sudo networksetup -setwebproxy Ethernet 127.0.0.1 7890; sudo networksetup -setsecurewebproxy Ethernet 127.0.0.1 7890'
  ;;
start)
  pgrep -f "tart run $NAME" >/dev/null || { nohup "$TART" run "$NAME" --dir="share:$SHARE" >/dev/null 2>&1 & }
  until [ -n "$(ip 2>/dev/null)" ] && nc -z -w2 "$(ip)" 22 2>/dev/null; do sleep 2; done
  # The VM reaches Google and Ling through the host's proxy (127.0.0.1:7890 in the VM).
  pkill -f "ssh -N -i $KEY" || true
  nohup ssh -N -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ServerAliveInterval=30 -R 7890:127.0.0.1:7890 "admin@$(ip)" >/dev/null 2>&1 &
  echo "VM at $(ip)"
  ;;
deploy)
  # A new file name each time: the shared folder keeps serving a replaced directory from its cache.
  n="cicada-$(date +%s).tgz"
  rm -f "$SHARE"/cicada-*.tgz
  tar -czf "$SHARE/$n" -C "$repo/build" Cicada.app
  run "pkill -x Cicada || true; sleep 1; rm -rf /Applications/Cicada.app; tar -xzf '/Volumes/My Shared Files/share/$n' -C /Applications
    : > /tmp/livesubs-dev-debug.log; open /Applications/Cicada.app; sleep 5; pgrep -lx Cicada"
  ;;
listen)
  run "~/bin/lsctl stop; sleep 1; : > /tmp/livesubs-dev-debug.log; ~/bin/lsctl start; sleep 3
    afplay '/Volumes/My Shared Files/share/$2'; sleep ${3:-8}; grep -v level /tmp/livesubs-dev-debug.log | cut -c1-200"
  ;;
ssh) shift; run "$@" ;;
stop) pkill -f "ssh -N -i $KEY" || true; "$TART" stop "$NAME" ;;
*) sed -n 2,10p "$0"; exit 1 ;;
esac
