#!/usr/bin/env bash
# Launch the live ISO in a QEMU window and share the host's internet with it.
#
# A TAP interface + dnsmasq (DHCP/DNS) + nftables masquerade is used instead of
# QEMU user-mode NAT: it works with the host's Wi-Fi (which cannot be bridged).
# Everything is torn down when QEMU exits.
set -euo pipefail

ISO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESULT="${RUN_RESULT_DIR:-$ISO_DIR/run}"
# build.sh writes to the project's iso/out; older builds used this script's
# own out/ directory. Accept either, newest first.
SRC_DIR="${SESSION_SRC_DIR:-$HOME/Code/cosmalia-session-dinit}"
ISO="$(find "$SRC_DIR/iso/out" "$ISO_DIR/out" -maxdepth 1 -name '*.iso' \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
[[ -n "$ISO" ]] || { echo "No ISO found in $SRC_DIR/iso/out or $ISO_DIR/out; run ./build.sh first" >&2; exit 1; }

# Interface names are limited to 15 characters, hence the short name here.
TAP="tap-cosdinit"
HOST_IP="10.55.0.1"
GUEST_RANGE="10.55.0.10,10.55.0.50,12h"
UPLINK="$(ip route | awk '/default/{print $5; exit}')"
[[ -n "$UPLINK" ]] || { echo "No default route on host" >&2; exit 1; }

OLD_FORWARD="$(cat /proc/sys/net/ipv4/ip_forward)"
DNSMASQ_PID=""
cleanup() {
  [[ -f "$RESULT/dnsmasq.pid" ]] && sudo kill "$(cat "$RESULT/dnsmasq.pid")" 2>/dev/null || true
  [[ -n "$DNSMASQ_PID" ]] && kill "$DNSMASQ_PID" 2>/dev/null || true
  sudo nft delete table inet cosmalia_dinit_share 2>/dev/null || true
  sudo ip link del "$TAP" 2>/dev/null || true
  sudo sysctl -w net.ipv4.ip_forward="$OLD_FORWARD" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 0' TERM INT

echo "==> Setting up TAP $TAP ($HOST_IP) -> $UPLINK NAT"
sudo ip tuntap add dev "$TAP" mode tap user "$(id -u)"
sudo ip addr add "$HOST_IP/24" dev "$TAP"
sudo ip link set "$TAP" up
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

sudo nft add table inet cosmalia_dinit_share
sudo nft add chain inet cosmalia_dinit_share postrouting '{ type nat hook postrouting priority srcnat; }'
sudo nft add chain inet cosmalia_dinit_share forward '{ type filter hook forward priority filter; policy accept; }'
sudo nft add rule inet cosmalia_dinit_share postrouting oifname "$UPLINK" counter masquerade

mkdir -p "$RESULT"
# The log file lives in the user-owned run/ directory, so the redirect does
# not need sudo (shellcheck cannot tell that from this line alone).
# shellcheck disable=SC2024
sudo dnsmasq --interface="$TAP" --bind-interfaces --except-interface=lo \
  --dhcp-range="$GUEST_RANGE" --dhcp-option="6,$HOST_IP" \
  --dhcp-leasefile="$RESULT/dnsmasq.leases" --pid-file="$RESULT/dnsmasq.pid" \
  --log-dhcp --no-daemon --log-facility=- >"$RESULT/dnsmasq.log" 2>&1 &
DNSMASQ_PID=$!

mkdir -p "$RESULT"
cp -f /usr/share/edk2/x64/OVMF_VARS.4m.fd "$RESULT/OVMF_VARS.fd"
rm -f "$RESULT/qemu.pid" "$RESULT/monitor.sock" "$RESULT/qga.sock"

echo "==> Booting $ISO (guest DHCP from $HOST_IP, NAT via $UPLINK)"
qemu-system-x86_64 \
  -name cosmalia-artix-live \
  -enable-kvm -cpu host -m 4096 -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file="$RESULT/OVMF_VARS.fd" \
  -cdrom "$ISO" -boot order=d \
  -vga qxl -display gtk \
  -monitor "unix:$RESULT/monitor.sock,server,nowait" \
  -serial "file:$RESULT/serial.log" \
  -netdev "tap,ifname=$TAP,script=no,downscript=no,id=n0" \
  -device virtio-net-pci,netdev=n0 \
  -device virtio-keyboard-pci -device virtio-mouse-pci \
  -chardev "socket,path=$RESULT/qga.sock,server=on,wait=off,id=qga0" \
  -device virtio-serial-pci -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -pidfile "$RESULT/qemu.pid"
