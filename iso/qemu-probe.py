#!/usr/bin/env python3
"""Verify the Artix/dinit live ISO through the serial console + QEMU HMP screenshots."""
import os
import re
import socket
import sys
import time

RESULT = sys.argv[1]
MONITOR = os.path.join(RESULT, "monitor.sock")
SERIAL = os.path.join(RESULT, "serial.sock")


def connect(path, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(path)
            s.settimeout(1.0)
            return s
        except OSError:
            time.sleep(0.25)
    raise RuntimeError(f"could not connect to {path}")


class Hmp:
    def __init__(self, path):
        self.s = connect(path)

    def cmd(self, line, wait=0.8):
        self.s.sendall((line + "\n").encode())
        time.sleep(wait)
        out = b""
        self.s.setblocking(False)
        try:
            while True:
                d = self.s.recv(65536)
                if not d:
                    break
                out += d
        except (BlockingIOError, OSError):
            pass
        self.s.setblocking(True)
        return re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", out.decode("utf-8", "replace"))


ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")
OSC = re.compile(r"\x1b\][^\x07]*(?:\x07|\x1b\\)")


def clean(text):
    text = OSC.sub("", text)
    text = ANSI.sub("", text)
    text = re.sub(r"\x1b[78]", "", text)
    return text.replace("\r", "")


def main():
    report = open(os.path.join(RESULT, "report.txt"), "w")

    def say(*a):
        msg = " ".join(str(x) for x in a)
        print(msg, flush=True)
        report.write(msg + "\n")
        report.flush()

    hmp = Hmp(MONITOR)
    ser = connect(SERIAL)
    say("=== connected to QEMU monitor and serial console ===")

    # Wait for the serial getty, then log in as root (empty password).
    boot = ""
    deadline = time.time() + 180
    while time.time() < deadline:
        boot += drain(ser, 0.5)
        if "login:" in boot:
            break
    say("=== boot reached login prompt ===")

    def login(timeout=10):
        for attempt in range(4):
            drain(ser, 0.5)
            ser.sendall(b"\r")
            time.sleep(0.5)
            ser.sendall(b"root\r")
            time.sleep(6)
            ser.sendall(b"\r")
            time.sleep(1)
            ser.sendall(b"echo __LOGIN_OK__\r")
            out = ""
            deadline = time.time() + timeout
            # the echoed command contains the marker too; require the real output
            while time.time() < deadline and out.count("__LOGIN_OK__") < 2:
                out += drain(ser, 0.4)
            if out.count("__LOGIN_OK__") >= 2:
                say(f"=== root shell ready on ttyS0 (attempt {attempt + 1}) ===")
                return True
        return False

    if not login():
        say("WARNING: serial root login failed; in-guest checks will be skipped")
        report.close()
        return

    counter = [0]

    def run(command, timeout=20):
        """Run a shell command on the VM and return its stdout, marker-delimited."""
        counter[0] += 1
        n = counter[0]
        begin, endmark = f"__B_{n}__", f"__E_{n}__"
        drain(ser, 0.5)  # discard pending kernel/service logs before the command
        ser.sendall((f"echo {begin}; {command}; echo {endmark}\r").encode())
        out = ""
        deadline = time.time() + timeout
        while time.time() < deadline and out.count(endmark) < 2:
            out += drain(ser, 0.4)
        lines = [l.strip() for l in clean(out).split("\n") if l.strip()]
        try:
            b = max(i for i, l in enumerate(lines) if begin in l)
            e = max(i for i, l in enumerate(lines) if endmark in l)
        except ValueError:
            return "NO MARKER (command timed out)"
        return "\n".join(lines[b + 1:e])

    checks = [
        ("kernel cmdline", "cat /proc/cmdline"),
        ("os release", "grep -E '^(NAME|PRETTY_NAME|ID|ID_LIKE)=' /etc/os-release"),
        ("pid 1", "cat /proc/1/comm"),
        ("system dinit services", "dinitctl list 2>&1 | head -40"),
        ("greetd status", "dinitctl status greetd 2>&1 || true"),
        ("greetd config", "cat /etc/greetd/config.toml"),
        ("greetd environments", "cat /etc/greetd/environments"),
        ("sessions", "loginctl list-sessions --no-legend 2>&1 || true"),
        ("session service", "for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do loginctl show-session $s -p Service -p Type -p Name -p State; done"),
        ("session processes", "pgrep -a 'cosmic-comp|noctalia|cosmic-settings-daemon|greetd|tuigreet' || true"),
        ("wayland socket", "ls -l /run/user/1000/wayland-* 2>&1 || true"),
        ("user dinit services", "sudo -u liveuser env XDG_RUNTIME_DIR=/run/user/1000 dinitctl --user list 2>&1 || true"),
        ("cosmalia log", "cat /run/user/1000/cosmalia-session.log 2>&1 || true"),
        ("packages", "pacman -Q cosmalia-session-dinit cosmic-comp-traffic noctalia greetd greetd-tuigreet alacritty cosmic-settings simdutf 2>&1; pacman -Q chromium brave-origin-bin ungoogled-chromium 2>/dev/null || true"),
        ("chromium libs", "ldd /usr/lib/chromium/chromium 2>&1 | grep 'not found' || echo ALL_LIBS_OK"),
        ("noctalia settings", "grep -E '^(config_version|builtin|mode|position)' /home/liveuser/.local/state/noctalia/settings.toml"),
        ("syncthing extension", "grep -i syncthing /home/liveuser/.local/state/noctalia/settings.toml && echo FOUND || echo CLEAN"),
        ("copied shortcuts", "ls -1 /home/liveuser/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/"),
        ("network address", "ip -4 addr show up | grep inet || true"),
        ("network route", "ip route | head -5"),
        ("DNS", "cat /etc/resolv.conf"),
        ("internet (curl)", "curl -sS --max-time 12 -o /dev/null -w 'HTTP %{http_code}\\n' https://example.com || echo FAILED"),
        ("wallpaper", "ls -l /usr/share/backgrounds/cosmalia-wallpaper.png; grep -A1 'wallpaper.default' /home/liveuser/.local/state/noctalia/settings.toml"),
        ("memory", "free -m | head -2"),
    ]
    for label, command in checks:
        say(f"--- {label} ---")
        say(run(command).strip())

    # Screenshot of the desktop started by greetd's initial_session.
    shot = os.path.join(RESULT, "desktop.ppm")
    hmp.cmd(f"screendump {shot}", 2.0)
    say(f"=== desktop screenshot: {shot} ({os.path.getsize(shot) if os.path.exists(shot) else 0} bytes) ===")

    # End the autologin session: greetd must present the tuigreet TUI greeter.
    say("--- terminate liveuser session ---")
    say(run("loginctl terminate-user liveuser").strip())
    time.sleep(10)
    greeter = os.path.join(RESULT, "greeter.ppm")
    hmp.cmd(f"screendump {greeter}", 2.0)
    say(f"=== greeter screenshot: {greeter} ({os.path.getsize(greeter) if os.path.exists(greeter) else 0} bytes) ===")
    say("--- greeter processes ---")
    say(run("pgrep -a 'tuigreet|greetd' || true").strip())

    # Log back in through tuigreet: username is pre-filled, password is empty.
    for _ in range(2):
        hmp.cmd("sendkey ret", 1.0)
        time.sleep(1.5)
    time.sleep(15)
    relogin = os.path.join(RESULT, "relogin.ppm")
    hmp.cmd(f"screendump {relogin}", 2.0)
    say(f"=== relogin screenshot: {relogin} ({os.path.getsize(relogin) if os.path.exists(relogin) else 0} bytes) ===")
    say("--- processes after greeter login ---")
    say(run("pgrep -a 'cosmic-comp|noctalia|tuigreet' || true").strip())
    say("--- sessions after greeter login ---")
    say(run("loginctl list-sessions --no-legend").strip())

    report.close()
    ser.close()


def drain(s, wait=0.5):
    time.sleep(wait)
    out = b""
    s.setblocking(False)
    try:
        while True:
            d = s.recv(65536)
            if not d:
                break
            out += d
    except (BlockingIOError, OSError):
        pass
    s.setblocking(True)
    return out.decode("utf-8", "replace")


if __name__ == "__main__":
    main()
