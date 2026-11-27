#!/usr/bin/env bash
# Boot the live ISO in QEMU with a blank disk and exercise the integrated
# Artix (Calamares) installer.  Evidence is written to test-results/installer.
set -euo pipefail

ISO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESULT="${INSTALLER_RESULT_DIR:-$ISO_DIR/test-results/installer}"
ISO="${INSTALLER_ISO:-$(ls -t "$ISO_DIR"/out/*.iso 2>/dev/null | head -1)}"
[[ -n "$ISO" ]] || { echo "No ISO found in $ISO_DIR/out; run ./build.sh first" >&2; exit 1; }

mkdir -p "$RESULT"
cp -f /usr/share/edk2/x64/OVMF_VARS.4m.fd "$RESULT/OVMF_VARS.fd"
rm -f "$RESULT"/monitor.sock "$RESULT"/qmp.sock "$RESULT"/serial.sock "$RESULT"/qga.sock \
      "$RESULT"/qemu.pid "$RESULT"/installer-*.png "$RESULT"/installer-*.ppm
if [[ ! -f "$RESULT/disk.qcow2" || "${1:-}" == "--fresh" ]]; then
  qemu-img create -f qcow2 "$RESULT/disk.qcow2" 40G >/dev/null
fi

echo "==> Booting $ISO with blank disk $RESULT/disk.qcow2"
echo "==> Evidence: $RESULT"

qemu-system-x86_64 \
  -name cosmalia-installer-test \
  -enable-kvm -cpu host -m 4096 -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file="$RESULT/OVMF_VARS.fd" \
  -cdrom "$ISO" -boot order=d \
  -drive "file=$RESULT/disk.qcow2,if=virtio,format=qcow2" \
  -vga qxl -display none -vnc 127.0.0.1:9 \
  -monitor "unix:$RESULT/monitor.sock,server,nowait" \
  -qmp "unix:$RESULT/qmp.sock,server,nowait" \
  -serial "unix:$RESULT/serial.sock,server,nowait" \
  -netdev user,id=n0,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3 -device virtio-net-pci,netdev=n0 \
  -device virtio-keyboard-pci -device virtio-mouse-pci \
  -chardev "socket,path=$RESULT/qga.sock,server=on,wait=off,id=qga0" \
  -device virtio-serial-pci -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -pidfile "$RESULT/qemu.pid" &

QPID=$!
trap 'kill "$QPID" 2>/dev/null || true' EXIT

python3 "$ISO_DIR/installer-probe.py" "$RESULT"
