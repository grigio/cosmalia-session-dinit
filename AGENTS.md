# Cosmalia / dinit notes

## Dinit basics

Services are **single files**, not directories with `start/dependencies/type`:

```ini
property = value
property += value-addendum   # additive for some properties
# comment
```

User service dirs, in order: `$XDG_CONFIG_HOME/dinit.d`, `~/.config/dinit.d`,
`/etc/dinit.d/user`, `/usr/lib/dinit.d/user`, `/usr/local/lib/dinit.d/user`.
This package installs to `/etc/dinit.d/user/`, mode `644`.

| Type | Use |
|------|-----|
| `process` | One supervised process |
| `bgprocess` | Daemon that writes a PID file |
| `scripted` | Custom start/stop commands |
| `internal` | Grouping only (targets) |
| `triggered` | Internal, waits for an external trigger |

| Property | Behaviour | systemd |
|----------|-----------|---------|
| `depends-on: svc` | Start first; stop cascades if svc stops | `Requires=` + `After=` |
| `depends-ms: svc` | Start first; no stop cascade | `Wants=` + `After=` |
| `waits-for: svc` | Wait for start/fail, no requirement | weak `After=` |
| `after: svc` | Ordering only | `After=` |

Cycles are rejected at load time (`dinit-check` / `dinitctl reload` fail fast).

```ini
# cosmalia-session.target  (internal = systemd .target)
type = internal
depends-ms: noctalia
depends-ms: cosmic-settings-daemon
```

`restart = on-failure` ignores clean signals; `smooth-recovery = yes` restarts
without stopping dependents; `restart-limit-count = 3` (interval 10s) caps loops;
`restart = always` also restarts on clean exits.

## dinitctl (user instance)

| Command | Notes |
|---------|-------|
| `dinitctl --user start\|stop\|restart <svc>` | Manage a service |
| `dinitctl --user reload <svc>` | Reload definition (needs a name) |
| `dinitctl --user is-started <svc>` | 0 = started, 1 = not started (**not** `is-active`) |
| `dinitctl --user status <svc>` / `catlog <svc>` | State+PID / dump log buffer (no `-f`) |
| `dinitctl --user list` / `shutdown` | List services / stop all |
| `dinitctl --user setenv K=V ...` / `unsetenv K ...` | Manager environment |
| `dinit-check --user <svc>` | Verify resolution/deps (**no** `verify` command) |

Systemd → dinit: `Wants=` → `depends-ms:`, `Requires=` → `depends-on:`,
`After=` → `after:`, `PartOf=target` → nothing, `Restart=on-failure` →
`restart = on-failure`, `daemon-reload` → `dinitctl --user reload <svc>`.

## Session rules

1. **No `graphical.target`.** Turnstiled may be absent; the launcher owns
   `cosmalia-session.target`. Never add `depends-on: graphical.target`.
2. **Order:** `cosmic-comp` → find Wayland socket → publish env →
   `dinitctl --user start cosmalia-session.target`. Noctalia needs `WAYLAND_DISPLAY`.
3. **No back-dependency** from a service to the target: dinit rejects the cycle.
   Stopping the target already stops its `depends-ms` services.
4. **Command names:** `is-active`, `verify`, bare `reload` do not exist.
   After package upgrades, `dinitctl --user reload <svc>`; new services load on demand.
5. **Portals are D-Bus activated**, not dinit units. Stop stale ones with an
   anchored `pkill -u "$USER" -f '^/usr/lib/xdg-desktop-portal'` and let D-Bus
   restart them. `cosmalia-portals.conf` must route ScreenCast/Screenshot to
   `wlr` (cosmic backend crashes on `ext_image_copy_capture_session_v1`). Ship
   `/etc/xdg/xdg-desktop-portal-wlr/cosmalia` with `chooser_type=none` and a fixed
   `output_name`.
6. **Env propagation:** no `--systemd` for `dbus-update-activation-environment`.
   Pass `WAYLAND_DISPLAY`, `XDG_CURRENT_DESKTOP`, `XDG_SESSION_TYPE`,
   `XDG_SESSION_DESKTOP`, `XDG_SESSION_ID`, `XDG_SESSION_CLASS`, `DESKTOP_SESSION`,
   `XDG_RUNTIME_DIR`, `PATH` to both D-Bus activation and `dinitctl --user setenv`.
   Without `XDG_SESSION_ID`, Noctalia's lock/idle monitoring breaks.
7. **Polkit + cgroup:** dinit user services live in `/user-1000.userspawn`, not
   the logind session cgroup, so polkit reports `subject.local/active = false`.
   Authorise NetworkManager by group (`wheel`/`sudo`), not locality.
8. **Brightness:** Noctalia writes `/sys/class/backlight/*/brightness` directly;
   a udev rule must `chgrp video` / `chmod 0664` the sysfs file.
9. **Keyring:** if the `login` keyring password differs from the account
   password, PAM cannot unlock it and a prompt appears every login.
10. **DRM:** only one DRM compositor at a time; stop it before manual tests.
    `COSMIC_DRM_BLOCK_DEVICES` needs both `cardN` and its `major:minor`.

## Live ISO / build

- **Artix only:** `system`/`world`/`galaxy` + local `[cosmalia]`. No Arch repos
  or packages. `mkarchiso` is vendored in `iso/tools/` and prefers Artix
  `basestrap`/`artix-chroot` (`artools-base`) over `pacstrap`/`arch-chroot`.
- Boot chain: initramfs → `switch_root /sbin/init` (→ `dinit-init`) → dinit →
  greetd + tuigreet on vt1 → autologin `liveuser` → `/usr/bin/cosmalia-session`
  → user dinit `cosmalia-session.target`.
- GRUB/syslinux have **two** entries: normal, and safe `copytoram=y`. Neither
  registers `console=ttyS0` — on bare metal that can hang right after
  `squashfs: version 4.0`. The serial getty still runs, so QEMU tests work.
- `cosmalia_bootlog` prints `cosmalia:` stage markers to the console and
  `BOOTLOG.TXT` on `ARCHISO_EFI`. `root ready: switch_root -> /sbin/init (dinit)`
  means dinit is next.
- Artix `ungoogled-chromium` ships **`chromium.desktop`** (`Exec=chromium`), so
  the Noctalia dock pin must be `chromium`.
- Flash with `dd bs=1M conv=nocreat oflag=direct`; verify read-back SHA-256.
- CI: `.github/workflows/iso.yml` builds on `v*` tags and attaches the ISO
  (`--clobber`). Current good release: **v1.6.0** (pins cosmic-comp-traffic
  `epoch-1.12.0` in the ISO).
