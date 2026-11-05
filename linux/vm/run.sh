#!/bin/bash
# Runs the Ubuntu 24.04 arm64 desktop test VM under QEMU (HVF), headless: VNC on :2, the QEMU
# monitor on $VM/monitor.sock (screendump works whatever the compositor allows), SSH on
# localhost:2223. First run builds the disk from the cloud image and cloud-init installs a GNOME
# desktop with auto-login, so the app runs in a real session.
#   VM=~/VMs/cicada-ubuntu linux/vm/run.sh        # needs noble-arm64.img and vm_key in $VM
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
VM="${VM:-$HOME/VMs/cicada-ubuntu}"
cd "$VM"
share=/opt/homebrew/share/qemu

if [ ! -f disk.qcow2 ]; then
  qemu-img create -q -f qcow2 -F qcow2 -b noble-arm64.img disk.qcow2 40G
  dd if=/dev/zero of=vars.fd bs=1m count=64 2>/dev/null
  rm -rf seed && mkdir seed
  sed "s|@KEY@|$(cat vm_key.pub)|" "$here/user-data" > seed/user-data
  printf 'instance-id: cicada-ubuntu\nlocal-hostname: cicada-ubuntu\n' > seed/meta-data
  rm -f seed.iso && hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata -o seed.iso seed
fi

# A real (if silent) sound card, so PipeWire makes a proper sink whose monitor we capture. Virtio:
# the guest froze loading snd-hda-intel for the emulated Intel HDA under HVF.
qemu-system-aarch64 \
  -name cicada-ubuntu -machine virt,highmem=on -accel hvf -cpu host -smp 4 -m 6G \
  -drive if=pflash,format=raw,readonly=on,file="$share/edk2-aarch64-code.fd" \
  -drive if=pflash,format=raw,file=vars.fd \
  -drive file=disk.qcow2,if=virtio,discard=unmap \
  -drive file=seed.iso,media=cdrom,if=virtio,readonly=on \
  -device virtio-gpu-pci,xres=1600,yres=1000 -device virtio-keyboard-pci -device virtio-tablet-pci \
  -audiodev none,id=snd,timer-period=20000 -device virtio-sound-pci,audiodev=snd \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2223-:22 \
  -vnc 127.0.0.1:2 -monitor unix:"$VM/monitor.sock",server,nowait -daemonize -pidfile "$VM/qemu.pid" </dev/null >/dev/null 2>"$VM/qemu.log" || { cat "$VM/qemu.log" >&2; exit 1; }
echo "started; ssh: linux/vm/vmctl.sh ssh"
