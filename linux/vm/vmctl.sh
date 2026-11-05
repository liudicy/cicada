#!/bin/bash
# Small helpers for the Ubuntu test VM.
#   vmctl.sh ssh [cmd…]     run in the VM as cicada (inside the desktop session's environment)
#   vmctl.sh shot out.png   screenshot of the VM's screen through the QEMU monitor
#   vmctl.sh wake           a key press through QEMU (wakes a blanked screen)
#   vmctl.sh type abc       types through QEMU's keyboard
#   vmctl.sh stop
set -euo pipefail
VM="${VM:-$HOME/VMs/cicada-ubuntu}"
# One shared connection (ControlMaster): QEMU's user networking here wedged after many short ones.
ssh_=(ssh -q -i "$VM/vm_key" -p 2223 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      -o ConnectTimeout=8 -o ControlMaster=auto -o ControlPath="$VM/ssh.sock" -o ControlPersist=600 cicada@127.0.0.1)
case "${1:-}" in
  ssh) shift; if [ $# -eq 0 ]; then exec "${ssh_[@]}"; fi
       # The GNOME session's bus, display and audio, so commands act inside the logged-in desktop.
       exec "${ssh_[@]}" "export XDG_RUNTIME_DIR=/run/user/\$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 XAUTHORITY=\$(ls /run/user/\$(id -u)/.mutter-Xwaylandauth.* 2>/dev/null | head -1); $*" ;;
  shot) out="$(cd "$(dirname "${2:?out.png}")" && pwd)/$(basename "$2")"; ppm="${out%.png}.ppm"
        printf 'screendump %s\n' "$ppm" | nc -U -w 2 "$VM/monitor.sock" >/dev/null; sleep 1
        sips -s format png "$ppm" --out "$out" >/dev/null && rm -f "$ppm" && echo "$out" ;;
  # Real input through QEMU (xdotool only reaches XWayland, not the compositor): wakes a blanked screen.
  wake) printf 'sendkey shift\n' | nc -U -w 2 "$VM/monitor.sock" >/dev/null ;;
  # Typing through QEMU's keyboard (lowercase letters and digits).
  type) for ((i = 0; i < ${#2}; i++)); do printf 'sendkey %s\n' "${2:i:1}"; sleep 0.2; done | nc -U -w 3 "$VM/monitor.sock" >/dev/null ;;
  stop) printf 'system_powerdown\n' | nc -U -w 2 "$VM/monitor.sock" >/dev/null || true ;;
  *) sed -n 2,8p "$0"; exit 1 ;;
esac
