#!/usr/bin/env bash
# Full end-to-end installer check: fresh disk -> drive Calamares -> boot the
# installed system from disk. Evidence is written to test-results/installer/.
set -euo pipefail

ISO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESULT="${INSTALLER_RESULT_DIR:-$ISO_DIR/test-results/installer}"
mkdir -p "$RESULT"

# Always start from a blank disk and fresh UEFI variables.
rm -f "$RESULT/disk.qcow2" "$RESULT/OVMF_VARS.fd" "$RESULT/OVMF_VARS.installed.fd"
qemu-img create -f qcow2 "$RESULT/disk.qcow2" 40G >/dev/null

echo "==> Starting live ISO + installer VM"
"$ISO_DIR/run-installer-vm.sh" &
QPID=$!
cleanup() { kill "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> Probing the live environment and launching Calamares"
python3 "$ISO_DIR/installer-probe.py" "$RESULT"

echo "==> Driving the wizard"
python3 "$ISO_DIR/installer-drive.py" "$RESULT"

echo "==> Capturing the final installer page"
python3 "$ISO_DIR/vmctl.py" "$RESULT" screenshot final-installed-page || true
python3 "$ISO_DIR/qga.py" "$RESULT" run "tail -40 /tmp/calamares.log" || true

echo "==> Stopping installer VM"
cleanup
trap - EXIT

echo "==> Booting the installed disk (without the ISO)"
"$ISO_DIR/test-installed.sh"

echo
echo "==> Installed-system report:"
cat "$RESULT/installed-report.txt"
