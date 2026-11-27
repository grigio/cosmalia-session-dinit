#!/usr/bin/env python3
"""Drive the Calamares wizard in the test VM (1024x768 framebuffer)."""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RESULT = sys.argv[1] if len(sys.argv) > 1 else "test-results/installer"
# QEMU absolute pointer coordinates scale to the 1024x768 framebuffer.
SX, SY = 32, 42.7


def qga(*args):
    return subprocess.run([sys.executable, os.path.join(HERE, "qga.py"), RESULT, *map(str, args)],
                          capture_output=True, text=True).stdout.strip()


def vmctl(*args):
    return subprocess.run([sys.executable, os.path.join(HERE, "vmctl.py"), RESULT, *map(str, args)],
                          capture_output=True, text=True).stdout.strip()


def click(x, y, pause=1.2):
    out = qga("click", int(x * SX), int(y * SY))
    time.sleep(pause)
    return out


def typ(text, pause=0.3):
    vmctl("type", text)
    time.sleep(pause)


def shot(name):
    subprocess.run([sys.executable, os.path.join(HERE, "vmctl.py"), RESULT, "screenshot", name],
                   capture_output=True, text=True)
    subprocess.run(["magick", os.path.join(RESULT, f"{name}.ppm"), os.path.join(RESULT, f"{name}.png")],
                   capture_output=True, text=True)


def log_tail(n=12):
    return qga("run", f"tail -{n} /tmp/calamares.log | tr -d '\\r' | tail -{n}")


def main():
    shot("step-welcome")
    # welcome -> location -> keyboard -> partition -> users
    for _ in range(4):
        click(881, 623)
    shot("step-users")

    # Users form (see the screenshot in step-users.png).
    click(295, 174); typ("Test User")
    click(295, 232); typ("testuser")
    click(295, 294); typ("cosmalia-test")
    click(295, 357); typ("cosmaliatest")
    click(500, 357); typ("cosmaliatest")
    shot("step-users-filled")

    # users -> summary; the summary page's Next button sits lower.
    click(881, 623)
    shot("step-summary")
    click(881, 735, pause=2)

    # "Continue with installation?" confirmation dialog.
    click(615, 470, pause=3)
    shot("installing")
    print("installation started; polling...")

    for i in range(60):
        time.sleep(6)
        out = qga("run", "grep -iE 'installation failed|completion: succeeded|"
                         "installed Limine with entries|failed to' /tmp/calamares.log | tail -4 || true")
        if i % 5 == 0:
            print(f"[{i * 6}s]", out.replace("\n", " | ") or "(no log markers yet)")
        if "installation failed" in out.lower():
            print("FAILURE DETECTED")
            break
        if "completion: succeeded" in out:
            print("INSTALLATION COMPLETED")
            break

    print("final log markers:", qga("run", "grep -iE 'installation failed|installed Limine with|"
                                          "installed system configured|failed' /tmp/calamares.log | tail -10 || true"))
    shot("final-installed-page")
    print("--- log tail ---")
    print(log_tail())


if __name__ == "__main__":
    main()
