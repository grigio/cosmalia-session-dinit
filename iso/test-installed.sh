#!/usr/bin/env bash
# Boot the disk produced by test-installer.sh (no live ISO) and verify that the
# installed Cosmalia environment comes up.
set -euo pipefail

ISO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESULT="${INSTALLER_RESULT_DIR:-$ISO_DIR/test-results/installer}"
DISK="$RESULT/disk.qcow2"
[[ -f "$DISK" ]] || { echo "No installed disk at $DISK; run ./test-installer.sh first" >&2; exit 1; }

# Reuse the OVMF vars from the install run: Limine registered its EFI entry there.
cp -f "$RESULT/OVMF_VARS.fd" "$RESULT/OVMF_VARS.installed.fd"
rm -f "$RESULT"/installed-*.png "$RESULT"/installed-*.ppm "$RESULT"/installed-report.txt \
      "$RESULT"/installed-monitor.sock "$RESULT"/installed-serial.sock "$RESULT"/installed-qmp.sock \
      "$RESULT"/installed-qga.sock "$RESULT"/installed-qemu.pid

echo "==> Booting installed system from $DISK"

qemu-system-x86_64 \
  -name cosmalia-installed-test \
  -enable-kvm -cpu host -m 4096 -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file="$RESULT/OVMF_VARS.installed.fd" \
  -drive "file=$DISK,if=virtio,format=qcow2" \
  -vga qxl -display none -vnc 127.0.0.1:10 \
  -monitor "unix:$RESULT/installed-monitor.sock,server,nowait" \
  -qmp "unix:$RESULT/installed-qmp.sock,server,nowait" \
  -serial "unix:$RESULT/installed-serial.sock,server,nowait" \
  -netdev user,id=n0,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3 -device virtio-net-pci,netdev=n0 \
  -device virtio-keyboard-pci -device virtio-mouse-pci \
  -chardev "socket,path=$RESULT/installed-qga.sock,server=on,wait=off,id=qga0" \
  -device virtio-serial-pci -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -pidfile "$RESULT/installed-qemu.pid" &

QPID=$!
trap 'kill "$QPID" 2>/dev/null || true' EXIT

python3 "$ISO_DIR/installed-probe.py" "$RESULT"
