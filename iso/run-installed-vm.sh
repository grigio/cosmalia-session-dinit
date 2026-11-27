#!/usr/bin/env bash
# Boot the installed Cosmalia system from disk in QEMU (leave it running).
set -euo pipefail

# Show the VM in a GTK window using the native Wayland backend (no XWayland).
export GDK_BACKEND=wayland

ISO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESULT="${INSTALLER_RESULT_DIR:-$ISO_DIR/test-results/installer}"
DISK="$RESULT/disk.qcow2"
[[ -f "$DISK" ]] || { echo "No installed disk at $DISK; install first" >&2; exit 1; }

# Reuse the OVMF vars from the install run: Limine's EFI entry lives there.
[[ -f "$RESULT/OVMF_VARS.installed.fd" ]] || \
  cp -f "$RESULT/OVMF_VARS.fd" "$RESULT/OVMF_VARS.installed.fd"
rm -f "$RESULT"/installed-qemu.pid "$RESULT"/installed-monitor.sock \
      "$RESULT"/installed-qmp.sock "$RESULT"/installed-serial.sock "$RESULT"/installed-qga.sock

echo "==> Booting installed system from $DISK"
exec qemu-system-x86_64 \
  -name cosmalia-installed \
  -enable-kvm -cpu host -m 4096 -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file="$RESULT/OVMF_VARS.installed.fd" \
  -drive "file=$DISK,if=virtio,format=qcow2" \
  -vga qxl -display gtk \
  -monitor "unix:$RESULT/installed-monitor.sock,server,nowait" \
  -qmp "unix:$RESULT/installed-qmp.sock,server,nowait" \
  -serial "unix:$RESULT/installed-serial.sock,server,nowait" \
  -netdev user,id=n0,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3 -device virtio-net-pci,netdev=n0 \
  -device virtio-keyboard-pci -device virtio-mouse-pci \
  -chardev "socket,path=$RESULT/installed-qga.sock,server=on,wait=off,id=qga0" \
  -device virtio-serial-pci -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -pidfile "$RESULT/installed-qemu.pid"
