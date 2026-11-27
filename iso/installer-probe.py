#!/usr/bin/env python3
"""Verify the integrated Artix Calamares installer inside the live VM and start it.

Uses QEMU Guest Agent (available in the ISO) for reliable in-guest output.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qga import Qga
from vmctl import Hmp

RESULT = sys.argv[1]


def main():
    report = open(os.path.join(RESULT, "installer-report.txt"), "w")

    def say(*a):
        msg = " ".join(str(x) for x in a)
        print(msg, flush=True)
        report.write(msg + "\n")
        report.flush()

    # Give the guest agent time to appear after boot.
    qga = None
    deadline = time.time() + 180
    while time.time() < deadline:
        try:
            qga = Qga()
            qga.run("echo READY")
            break
        except Exception:
            time.sleep(2)
    if qga is None:
        say("ERROR: QEMU Guest Agent did not become available")
        report.close()
        return
    say("=== QEMU Guest Agent ready ===")

    checks = [
        ("live OS", "cat /etc/os-release | grep -E '^(NAME|PRETTY_NAME|ID)='"),
        ("installer packages", "pacman -Q calamares limine qt6-wayland efibootmgr dosfstools btrfs-progs squashfs-tools rsync 2>/dev/null"),
        ("installer launcher", "ls -l /usr/local/bin/cosmalia-installer /usr/local/bin/cosmalia-postinstall /usr/local/bin/cosmalia-limine-install"),
        ("desktop entry", "grep -E '^(Name|Exec|Comment)=' /usr/share/applications/cosmalia-installer.desktop"),
        ("calamares sequence", "grep -E 'welcome|partition|unpackfs|shellprocess@cosmalia|shellprocess@limine|umount' /etc/calamares/settings.conf | tail -20"),
        ("unpackfs source", "grep -E 'source:|sourcefs:|destination:' /etc/calamares/modules/unpackfs.conf"),
        ("custom configs", "ls /etc/calamares/modules/"),
        ("branding", "grep -E 'productName|bootloaderEntryName' /usr/share/calamares/branding/cosmalia/branding.desc"),
        ("branding assets", "ls -1 /usr/share/calamares/branding/cosmalia/"),
        ("calamares binary", "calamares --version 2>&1 | head -3 || true"),
        ("calamares libs", "ldd /usr/lib/libcalamares.so.3.4.2 2>/dev/null | grep 'not found' || echo ALL_LIBS_OK"),
        ("limine binary", "limine --version 2>&1 | head -2 || true"),
        ("live squashfs", "ls -lh /run/artix/bootmnt/cosmalia/x86_64/airootfs.sfs"),
        ("target disk", "lsblk -o NAME,SIZE,TYPE /dev/vda | head -6"),
    ]
    for label, command in checks:
        say(f"--- {label} ---")
        say(qga.run(command).strip())

    say("=== launching Calamares in the live Wayland session ===")
    # The Noctalia bar covers the bottom-right navigation buttons in a
    # 1024x768 framebuffer; move it to the top and hide the dock for the
    # automated run (this only changes the live user's settings).
    say(qga.run(
        'f=/home/liveuser/.local/state/noctalia/settings.toml; '
        'awk \'/^\\[dock\\]/{d=1} d&&/^enabled = true/{sub(/true/,"false");d=0} '
        '{print}\' "$f" > "$f.tmp" && mv "$f.tmp" "$f" && chown liveuser:liveuser "$f"; '
        'awk \'/^\\[bar.default\\]/{b=1} b&&/^position = "bottom"/{sub(/bottom/,"top");b=0} '
        '{print}\' "$f" > "$f.tmp" && mv "$f.tmp" "$f" && chown liveuser:liveuser "$f"; '
        'rm -f /tmp/kdsingleapp-* /tmp/calamares-root-*; '
        'wl=$(basename "$(ls /run/user/1000/wayland-* 2>/dev/null | head -1)"); '
        'echo "WAYLAND=$wl"; '
        'nohup env LANG=en_US.UTF-8 LC_ALL=C.UTF-8 XDG_RUNTIME_DIR=/run/user/1000 '
        'WAYLAND_DISPLAY="$wl" QT_QPA_PLATFORM=wayland calamares -D8 >/tmp/calamares.log 2>&1 & '
        'echo "LAUNCHED=$!"; sleep 12; pgrep -a calamares || echo NOT_RUNNING'
    ).strip())
    say("--- calamares log tail ---")
    say(qga.run("tail -20 /tmp/calamares.log").strip())

    hmp = Hmp(os.path.join(RESULT, "monitor.sock"))
    shot = os.path.join(RESULT, "installer-welcome.ppm")
    hmp.cmd(f"screendump {shot}", 2.0)
    say(f"=== installer screenshot: {shot} ({os.path.getsize(shot) if os.path.exists(shot) else 0} bytes) ===")
    report.close()


if __name__ == "__main__":
    main()
