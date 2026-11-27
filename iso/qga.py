#!/usr/bin/env python3
"""Run commands inside the VM through QEMU Guest Agent (QMP)."""
import base64
import json
import os
import socket
import sys
import time

RESULT = sys.argv[1] if len(sys.argv) > 1 else "test-results/installer"
QMP_SOCK = os.path.join(RESULT, "qmp.sock")
QGA_SOCK = os.path.join(RESULT, "qga.sock")


class Qmp:
    def __init__(self, sock=None):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(sock or QMP_SOCK)
        self.s.settimeout(5)
        self._read()  # greeting
        self.cmd({"execute": "qmp_capabilities"})

    def _read(self):
        time.sleep(0.15)
        data = b""
        self.s.setblocking(False)
        try:
            while True:
                chunk = self.s.recv(65536)
                if not chunk:
                    break
                data += chunk
        except (BlockingIOError, OSError):
            pass
        self.s.setblocking(True)
        return data.decode("utf-8", "replace")

    def cmd(self, obj):
        self.s.sendall((json.dumps(obj) + "\n").encode())
        raw = self._read()
        replies = [json.loads(l) for l in raw.splitlines() if l.startswith("{")]
        return replies[-1] if replies else {}

    def mouse(self, x, y, click=True):
        events = [
            {"type": "abs", "data": {"axis": "x", "value": int(x)}},
            {"type": "abs", "data": {"axis": "y", "value": int(y)}},
        ]
        if not click:
            return self.cmd({"execute": "input-send-event", "arguments": {"events": events}})
        self.cmd({"execute": "input-send-event", "arguments": {"events": events}})
        time.sleep(0.3)
        down = {"execute": "input-send-event", "arguments": {"events": [
            {"type": "btn", "data": {"button": "left", "down": True}}]}}
        up = {"execute": "input-send-event", "arguments": {"events": [
            {"type": "btn", "data": {"button": "left", "down": False}}]}}
        self.cmd(down)
        time.sleep(0.2)
        return self.cmd(up)


class Qga:
    """Guest agent commands go directly to the QGA chardev, not QMP."""

    def __init__(self, qmp=None, sock=None):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(sock or QGA_SOCK)
        self.s.settimeout(5)

    def cmd(self, obj):
        self.s.sendall((json.dumps(obj) + "\n").encode())
        time.sleep(0.15)
        data = b""
        self.s.setblocking(False)
        try:
            while True:
                chunk = self.s.recv(65536)
                if not chunk:
                    break
                data += chunk
        except (BlockingIOError, OSError):
            pass
        self.s.setblocking(True)
        replies = [json.loads(l) for l in data.decode("utf-8", "replace").splitlines() if l.startswith("{")]
        return replies[-1] if replies else {}

    def run(self, command, timeout=60, cwd=None):
        arg = ["-c", command]
        args = {"path": "/bin/sh", "arg": arg, "capture-output": True}
        if cwd:
            args["cwd"] = cwd
        r = self.cmd({"execute": "guest-exec", "arguments": args})
        if "error" in r:
            return f"QGA ERROR: {r['error']}"
        pid = r["return"]["pid"]
        deadline = time.time() + timeout
        while time.time() < deadline:
            st = self.cmd({"execute": "guest-exec-status", "arguments": {"pid": pid}})
            ret = st.get("return", {})
            if ret.get("exited"):
                out = base64.b64decode(ret.get("out-data", "")).decode("utf-8", "replace")
                err = base64.b64decode(ret.get("err-data", "")).decode("utf-8", "replace")
                return out + (("\n[stderr]\n" + err) if err else "")
            time.sleep(0.3)
        return "TIMEOUT"


def main():
    cmd = sys.argv[2]
    qmp = Qmp()
    if cmd == "run":
        print(Qga(qmp).run(" ".join(sys.argv[3:]), timeout=120))
    elif cmd == "click":
        print(qmp.mouse(sys.argv[3], sys.argv[4]))
    elif cmd == "key":
        # keysyms via QMP input-send-event
        keys = sys.argv[3:]
        events = []
        for k in keys:
            code = KEY.get(k.lower(), ord(k[0]) if len(k) == 1 else 0)
            events.append({"type": "key", "data": {"key": k if k in KEY else f"KEY_{k.upper()}"}})
        print(qmp.cmd({"execute": "input-send-event", "arguments": {"events": events}}))
    else:
        raise SystemExit("unknown command")


KEY = {
    "ret": "Return", "enter": "Return", "tab": "Tab", "space": "Space",
    "backspace": "Backspace", "esc": "Escape", "up": "Up", "down": "Down",
    "left": "Left", "right": "Right", "home": "Home", "end": "End",
}


if __name__ == "__main__":
    main()
