#!/usr/bin/env python3
"""Small helper to drive the QEMU VM used by test-installer.sh.

Usage:
  vmctl.py RESULT screenshot [NAME]     screendump -> NAME.png (default: screen)
  vmctl.py RESULT key KEY...            send keys through QEMU HMP
  vmctl.py RESULT type TEXT             type a string through QEMU HMP
  vmctl.py RESULT click X Y             absolute mouse click through QMP
  vmctl.py RESULT shell COMMAND...      run a command on the serial root console
"""
import json
import os
import re
import socket
import subprocess
import sys
import time

RESULT = sys.argv[1]
MONITOR = os.path.join(RESULT, "monitor.sock")
SERIAL = os.path.join(RESULT, "serial.sock")
QMP = os.path.join(RESULT, "qmp.sock")
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")
OSC = re.compile(r"\x1b\][^\x07]*(?:\x07|\x1b\\)")


def connect(path, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(path)
            s.settimeout(2.0)
            return s
        except OSError:
            time.sleep(0.2)
    raise RuntimeError(f"could not connect to {path}")


def drain(s, wait=0.3):
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


class Hmp:
    def __init__(self, path=None):
        self.s = connect(path or MONITOR)

    def cmd(self, line, wait=0.5):
        drain(self.s, 0.05)
        self.s.sendall((line + "\n").encode())
        time.sleep(wait)
        out = drain(self.s, 0.15)
        return ANSI.sub("", OSC.sub("", out)).replace("\r", "")


class Serial:
    def __init__(self):
        self.s = connect(SERIAL)
        self.n = 0
        self.logged_in = False

    def ensure_login(self):
        if self.logged_in:
            return
        # The socket may be connected after boot, so the initial getty prompt
        # was lost. A newline makes getty reprint it.
        self.s.sendall(b"\r")
        time.sleep(0.5)
        initial = drain(self.s, 0.5)
        if "login:" in initial or "Cosmalia" in initial:
            self.s.sendall(b"root\r")
            time.sleep(4)
            self.s.sendall(b"\r")
            time.sleep(0.5)
        self.logged_in = True

    def run(self, command, timeout=20):
        self.ensure_login()
        self.n += 1
        # Unique tokens avoid stale output from a previous (killed) driver.
        token = f"{os.getpid()}_{self.n}"
        begin, endmark = f"__B{token}__", f"__E{token}__"
        drain(self.s, 0.2)
        self.s.sendall((f"echo {begin}; {command}; echo {endmark}\r").encode())
        out = ""
        deadline = time.time() + timeout
        while time.time() < deadline and out.count(endmark) < 2:
            out += drain(self.s, 0.3)
        text = ANSI.sub("", OSC.sub("", out)).replace("\r", "")
        lines = [l.strip() for l in text.split("\n") if l.strip()]
        try:
            b = max(i for i, l in enumerate(lines) if begin in l)
            e = max(i for i, l in enumerate(lines) if endmark in l)
        except ValueError:
            return "NO MARKER (timeout)"
        return "\n".join(lines[b + 1:e])


class Qmp:
    def __init__(self):
        self.s = connect(QMP)
        drain(self.s, 0.1)
        self.cmd({"execute": "qmp_capabilities"})

    def cmd(self, obj):
        self.s.sendall((json.dumps(obj) + "\n").encode())
        time.sleep(0.2)
        return drain(self.s, 0.2)

    def click(self, x, y):
        events = [
            {"type": "mouse", "data": {"axis": "x", "value": int(x)}},
            {"type": "mouse", "data": {"axis": "y", "value": int(y)}},
            {"type": "btn", "data": {"button": "left", "down": True}},
            {"type": "btn", "data": {"button": "left", "down": False}},
        ]
        return self.cmd({"execute": "input-send-event", "arguments": {"events": events}})


SPECIAL = {
    "ret": "ret", "enter": "ret", "tab": "tab", "space": "spc",
    "backspace": "backspace", "esc": "esc", "up": "up", "down": "down",
    "left": "left", "right": "right", "home": "home", "end": "end",
}


def send_text(hmp, text):
    for ch in text:
        if ch == " ":
            key = "spc"
        elif ch.isupper():
            hmp.cmd("sendkey shift-down", 0.05)
            hmp.cmd(f"sendkey {ch.lower()}", 0.05)
            hmp.cmd("sendkey shift-up", 0.05)
            continue
        else:
            key = ch
        hmp.cmd(f"sendkey {key}", 0.04)


def main():
    cmd = sys.argv[2]
    args = sys.argv[3:]
    if cmd == "screenshot":
        name = args[0] if args else "screen"
        ppm = os.path.join(RESULT, f"{name}.ppm")
        png = os.path.join(RESULT, f"{name}.png")
        Hmp().cmd(f"screendump {ppm}", 2.0)
        subprocess.run(["convert", ppm, png], check=True)
        print(png, os.path.getsize(png))
    elif cmd == "key":
        h = Hmp()
        for k in args:
            h.cmd(f"sendkey {SPECIAL.get(k.lower(), k)}", 0.12)
    elif cmd == "type":
        send_text(Hmp(), " ".join(args))
    elif cmd == "click":
        print(Qmp().click(args[0], args[1]))
    elif cmd == "shell":
        ser = Serial()
        for line in args:
            print(f"$ {line}")
            print(ser.run(line, timeout=60))
    else:
        raise SystemExit(f"unknown command: {cmd}")


if __name__ == "__main__":
    main()
