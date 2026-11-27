#!/usr/bin/env python3
"""Verify the system installed by Calamares boots from disk with dinit."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qga import Qga
from vmctl import Hmp

RESULT = sys.argv[1]
QGA = os.path.join(RESULT, "installed-qga.sock")
MONITOR = os.path.join(RESULT, "installed-monitor.sock")


def main():
    report = open(os.path.join(RESULT, "installed-report.txt"), "w")

    def say(*a):
        msg = " ".join(str(x) for x in a)
        print(msg, flush=True)
        report.write(msg + "\n")
        report.flush()

    qga = None
    deadline = time.time() + 240
    while time.time() < deadline:
        try:
            q = Qga(sock=QGA)
            q.run("echo READY", timeout=10)
            qga = q
            break
        except Exception:
            time.sleep(3)

    hmp = Hmp(MONITOR)
    shot = os.path.join(RESULT, "installed-desktop.ppm")
    hmp.cmd(f"screendump {shot}", 2.0)
    say(f"=== installed desktop screenshot: {shot} "
        f"({os.path.getsize(shot) if os.path.exists(shot) else 0} bytes) ===")

    if qga is None:
        say("WARNING: QEMU Guest Agent unavailable in installed system")
        report.close()
        return
    say("=== QEMU Guest Agent ready ===")
    # The session's user dinit manager and the compositor need a few seconds
    # after QGA becomes available; sample the steady state, not the race.
    time.sleep(25)

    checks = [
        ("booted from disk", "findmnt -n -o SOURCE /; grep -o 'root=UUID=[^ ]*' /proc/cmdline"),
        ("cmdline", "cat /proc/cmdline"),
        ("pid 1", "cat /proc/1/comm"),
        ("os release", "grep -E '^(NAME|PRETTY_NAME|ID)=' /etc/os-release"),
        ("fstab", "grep -v '^#' /etc/fstab | grep -v '^$' | head -8"),
        ("boot files on ESP", "ls -lh /boot/efi/vmlinuz-linux /boot/efi/initramfs-linux*.img 2>&1 | head -6"),
        ("limine config", "cat /boot/efi/limine.conf 2>/dev/null || cat /boot/limine.conf 2>/dev/null"),
        ("greetd", "dinitctl status greetd 2>&1 | head -3; cat /etc/greetd/config.toml"),
        ("dinit services", "dinitctl list 2>&1 | head -30"),
        ("users (liveuser must be gone)", "getent passwd | grep -E '^(root|greeter|test|liveuser)' | cut -d: -f1,3,6"),
        ("live sudoers removed", "ls /etc/sudoers.d/99-liveuser 2>&1 || echo REMOVED"),
        ("wheel sudo rule", "cat /etc/sudoers.d/99-cosmalia-wheel 2>&1; "
                            "id -nG $(getent passwd | awk -F: '$3>=1000 && $3<65534 && $1!=\"nobody\" && $1!=\"liveuser\"{print $1; exit}') | tr ' ' '\\n' | grep -x wheel || echo NOT_IN_WHEEL"),
        ("initramfs config", "cat /etc/mkinitcpio.conf | grep HOOKS; ls -lh /boot/initramfs-linux*.img"),
        ("desktop processes", "pgrep -a 'cosmic-comp|noctalia|dinit|greetd|tuigreet' | head -10 || true"),
        ("user dinit services", "u=$(getent passwd | awk -F: '$3>=1000 && $3<65534 && $1!=\"nobody\" && $1!=\"liveuser\"{print $1; exit}'); echo USER=$u; sudo -u \"$u\" env XDG_RUNTIME_DIR=/run/user/$(id -u \"$u\") dinitctl --user list 2>&1 | head -20 || true"),
        ("cosmalia session log", "u=$(getent passwd | awk -F: '$3>=1000 && $3<65534 && $1!=\"nobody\" && $1!=\"liveuser\"{print $1; exit}'); cat /run/user/$(id -u \"$u\")/cosmalia-session.log 2>&1 | tail -12 || true"),
        ("packages", "pacman -Q cosmalia-session-dinit cosmic-comp-traffic noctalia greetd limine calamares nautilus 2>/dev/null"),
    ]
    for label, command in checks:
        say(f"--- {label} ---")
        say(qga.run(command, timeout=30).strip())
    report.close()


if __name__ == "__main__":
    main()
