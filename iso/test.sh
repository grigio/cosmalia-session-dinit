#!/usr/bin/env bash
# Boot the built ISO in QEMU (KVM + OVMF/UEFI + QXL) and verify Cosmalia.
set -euo pipefail

ISO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESULT="${TEST_RESULT_DIR:-$ISO_DIR/test-results}"
# build.sh writes to the project's iso/out; older builds used this script's
# own out/ directory. Accept either, newest first.
SRC_DIR="${SESSION_SRC_DIR:-$HOME/Code/cosmalia-session-dinit}"
ISO="$(find "$SRC_DIR/iso/out" "$ISO_DIR/out" -maxdepth 1 -name '*.iso' \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
[[ -n "$ISO" ]] || { echo "No ISO found in $SRC_DIR/iso/out or $ISO_DIR/out; run ./build.sh first" >&2; exit 1; }

mkdir -p "$RESULT"
cp -f /usr/share/edk2/x64/OVMF_VARS.4m.fd "$RESULT/OVMF_VARS.fd"
rm -f "$RESULT/monitor.sock" "$RESULT/qmp.sock" "$RESULT/qga.sock" "$RESULT/serial.sock" \
      "$RESULT/qemu.pid" "$RESULT/desktop.ppm" "$RESULT/desktop.png" \
      "$RESULT/greeter.ppm" "$RESULT/relogin.ppm" "$RESULT/report.txt" "$RESULT/serial.log"

echo "==> Booting $ISO"
echo "==> Results in $RESULT"

qemu-system-x86_64 \
  -name cosmalia-artix-live-test \
  -enable-kvm -cpu host -m "${QEMU_RAM:-4096}" -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file="$RESULT/OVMF_VARS.fd" \
  -cdrom "$ISO" -boot order=d \
  -vga qxl -display none -vnc 127.0.0.1:9 \
  -monitor "unix:$RESULT/monitor.sock,server,nowait" \
  -qmp "unix:$RESULT/qmp.sock,server,nowait" \
  -serial "unix:$RESULT/serial.sock,server,nowait" \
  -netdev user,id=n0,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3 \
  -device virtio-net-pci,netdev=n0 \
  -device virtio-keyboard-pci -device virtio-mouse-pci \
  -chardev "socket,path=$RESULT/qga.sock,server=on,wait=off,id=qga0" \
  -device virtio-serial-pci -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -pidfile "$RESULT/qemu.pid" &

QPID=$!
trap 'kill "$QPID" 2>/dev/null || true' EXIT

python3 "$ISO_DIR/qemu-probe.py" "$RESULT"
echo
echo "==> QEMU test finished. Report:"
cat "$RESULT/report.txt"
