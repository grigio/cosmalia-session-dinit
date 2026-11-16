# Dinit Notes for Cosmalia Session

## Format and paths

Services are **single files**, not directories with `start/dependencies/type`:

```ini
property = value
property += value-addendum   # additive for some properties
# comment
```

User dirs, in order: `$XDG_CONFIG_HOME/dinit.d`, `~/.config/dinit.d`,
`/etc/dinit.d/user`, `/usr/lib/dinit.d/user`, `/usr/local/lib/dinit.d/user`.
This package installs to `/etc/dinit.d/user/`, mode `644`.

## Rules learned while debugging

1. **No `graphical.target`.** Turnstiled may be absent; the launcher owns
   `cosmalia-session.target`. Never add `depends-on: graphical.target`.
2. **Order:** `cosmic-comp` → find its Wayland socket → publish env →
   `dinitctl --user start cosmalia-session.target`. Noctalia needs `WAYLAND_DISPLAY`.
3. **No back-dependency.** The target uses `depends-ms` on the services; adding
   `depends-on: cosmalia-session.target` to a service creates a cycle and nothing
   starts. Stopping the target already stops those services.
4. **Command names:** `is-active`, `verify` and bare `reload` do not exist —
   use `is-started`, `dinit-check --user` and `reload <svc>` (see tables).
5. **After package upgrades:** `dinitctl --user reload <svc>` for changed
   services; new ones load on demand via `start`.
6. **Portals are D-Bus activated**, not dinit units. Stop stale ones with an
   anchored pattern (`pkill -u "$USER" -f '^/usr/lib/xdg-desktop-portal'`) and let
   D-Bus restart them with fresh env. `cosmalia-portals.conf` must route
   ScreenCast/Screenshot to `wlr`; the cosmic backend crashes on
   `ext_image_copy_capture_session_v1`. Ship
   `/etc/xdg/xdg-desktop-portal-wlr/cosmalia` with `chooser_type=none` and a fixed
   `output_name` — cosmic-comp's interactive picker cancels immediately.
7. **Env propagation:** no `--systemd` for `dbus-update-activation-environment`
   (no systemd user manager). Pass `WAYLAND_DISPLAY`, `XDG_CURRENT_DESKTOP`,
   `XDG_SESSION_TYPE`, `XDG_SESSION_DESKTOP`, `XDG_SESSION_ID`, `XDG_SESSION_CLASS`,
   `DESKTOP_SESSION`, `XDG_RUNTIME_DIR`, `PATH` to both D-Bus activation and
   `dinitctl --user setenv`. Without `XDG_SESSION_ID`, Noctalia cannot resolve the
   logind session (lock/idle monitoring breaks).
8. **Polkit + cgroup gotcha:** dinit user services live in
   `/user-1000.userspawn`, not the logind session cgroup, so polkit reports
   `subject.local/active = false` and Noctalia's agent cannot register
   ("Cannot determine session the caller is in"). Authorise NetworkManager by
   group (`wheel`/`sudo`), not by locality.
9. **Brightness:** Noctalia writes `/sys/class/backlight/*/brightness` directly.
   elogind only tags backlights with `seat`; a udev rule must `chgrp video` /
   `chmod 0664` that file (GROUP/MODE on the device do not affect sysfs attributes).
10. **Keyring prompt:** Noctalia reads its encrypted storage key from the Secret
    Service at startup. If the `login` keyring password differs from the account
    password, PAM cannot unlock it and a prompt appears every login. Reset the
    keyring (back it up first) or change its password to match login.
11. **OBS:** aborts on startup with "Failed to load core OBS modules" if
    `obs-webrtc.so` cannot find `libssl.so.4`. Keep `openssl` 4 installed, with
    `openssl-3` alongside for older `libssl.so.3` consumers.
12. **DRM:** only one DRM compositor at a time; stop the greeter/compositor
    before testing manually or `/dev/dri/card*` gives "Permission denied".
    `agreety` works without a compositor; `regreet`/`tuigreet` do not.

## Service types

| Type | Use |
|------|-----|
| `process` | One supervised process |
| `bgprocess` | Daemon that writes a PID file |
| `scripted` | Custom start/stop commands |
| `internal` | Grouping only (targets) |
| `triggered` | Internal, waits for an external trigger |

## Dependencies

| Property | Behaviour | systemd |
|----------|-----------|---------|
| `depends-on: svc` | Start first; stop cascades if svc stops | `Requires=` + `After=` |
| `depends-ms: svc` | Start first; no stop cascade | `Wants=` + `After=` |
| `waits-for: svc` | Wait for start/fail, no requirement | weak `After=` |
| `after: svc` | Ordering only | `After=` |

Cycles are rejected at load time (`dinit-check` / `dinitctl reload` fail fast).

## Patterns

```ini
# cosmalia-session.target  (type internal = systemd .target)
type = internal
depends-ms: noctalia
depends-ms: cosmic-settings-daemon
```
```ini
# noctalia  (type process = systemd .service)
type = process
command = /usr/bin/noctalia
after: cosmic-settings-daemon
restart = on-failure
restart-delay = 1
stop-timeout = 5
```

## dinitctl (user instance)

| Command | Notes |
|---------|-------|
| `dinitctl --user start\|stop\|restart <svc>` | Manage a service |
| `dinitctl --user reload <svc>` | Reload its definition (needs a name) |
| `dinitctl --user is-started <svc>` | 0 = started, 1 = not started (**not** `is-active`) |
| `dinitctl --user status <svc>` / `catlog <svc>` | State+PID / dump log buffer (no `-f`) |
| `dinitctl --user list` / `shutdown` | List services / stop all |
| `dinitctl --user setenv K=V ...` / `unsetenv K ...` | Manager environment |
| `dinit-check --user <svc>` | Verify resolution/deps (**no** `verify` command) |

## systemd → dinit quick map

| systemd | dinit |
|---------|-------|
| `Wants=foo` | `depends-ms: foo` |
| `Requires=foo` | `depends-on: foo` |
| `After=foo` | `after: foo` |
| `PartOf=target` | nothing (stopped via the target's `depends-ms`) |
| `Restart=on-failure` | `restart = on-failure` |
| `daemon-reload` | `dinitctl --user reload <svc>` (per service) |
| `is-active` | `dinitctl --user is-started <svc>` |

`restart = on-failure` ignores clean signals; `smooth-recovery = yes` restarts
without stopping dependents; `restart-limit-count = 3` (interval 10s) caps loops;
`restart = always` also restarts on clean exits.
