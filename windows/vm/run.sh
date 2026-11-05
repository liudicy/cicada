#!/bin/bash
# Runs the Windows 11 ARM64 test VM under QEMU (HVF), headless: VNC on :1, the QEMU monitor on
# $VM/monitor.sock, SSH on localhost:2222. First run (no disk yet) installs Windows unattended.
#   VM=~/VMs/cicada-win11 windows/vm/run.sh        # needs win11.iso, virtio-win.iso, vm_key in $VM
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
VM="${VM:-$HOME/VMs/cicada-win11}"
cd "$VM"
share=/opt/homebrew/share/qemu

install=()
if [ ! -f disk.qcow2 ]; then
  qemu-img create -f qcow2 disk.qcow2 64G >/dev/null
  cp "$share/edk2-arm-vars.fd" vars.fd
  # The answer file and first-logon script on their own disc, with the host's SSH key and the
  # OpenSSH zip in case the built-in capability can't be downloaded.
  rm -rf seed && mkdir seed
  cp "$here/autounattend.xml" "$here/firstlogon.ps1" seed/
  cp vm_key.pub seed/authorized_keys
  [ -f OpenSSH-ARM64.zip ] && cp OpenSSH-ARM64.zip seed/
  rm -f seed.iso && hdiutil makehybrid -quiet -iso -joliet -o seed.iso seed
  install=(-drive file=win11.iso,media=cdrom,if=none,id=cd0,readonly=on -device usb-storage,drive=cd0,bootindex=0
           -drive file=seed.iso,media=cdrom,if=none,id=cd1,readonly=on -device usb-storage,drive=cd1)
fi

# No TPM: HVF refuses tpm-tis-device (HV_BAD_ARGUMENT); the answer file bypasses Windows 11's check.
qemu-system-aarch64 \
  -name cicada-win11 -machine virt,highmem=on -accel hvf -cpu host -smp 4 -m 8G -device qemu-xhci \
  -drive if=pflash,format=raw,readonly=on,file="$share/edk2-aarch64-code.fd" \
  -drive if=pflash,format=raw,file=vars.fd \
  -device nvme,drive=hd,serial=cicada,bootindex=1 -drive file=disk.qcow2,if=none,id=hd,discard=unmap \
  ${install[@]+"${install[@]}"} \
  -drive file=virtio-win.iso,media=cdrom,if=none,id=cd2,readonly=on -device usb-storage,drive=cd2 \
  -device virtio-gpu-pci -device usb-kbd -device usb-tablet \
  -audiodev none,id=snd -device usb-audio,audiodev=snd \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 \
  -vnc 127.0.0.1:1 -monitor unix:"$VM/monitor.sock",server,nowait -daemonize -pidfile "$VM/qemu.pid" </dev/null >/dev/null 2>"$VM/qemu.log" || { cat "$VM/qemu.log" >&2; exit 1; }
