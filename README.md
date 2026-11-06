# Cosmalia — Minimal COSMIC Desktop

![Cosmalia Desktop](./cosmalia-session-dinit.png)

**Cosmalia** is a minimal Wayland desktop running in under 0.8 GB RAM, built from:

- **cosmic-comp** or **cosmic-comp-traffic** - COSMIC Wayland compositor (traffic-light decorations, blur, animations, 3-finger swipes, in-process Alt+Tab)
- **Noctalia** - Shell: bar, dock, launcher, notifications, lock screen, idle/suspend, MPRIS, polkit agent

`cosmalia-session` is the opinionated XDG session that starts them together. It appears in any Wayland-capable login manager (ly, greetd, SDDM, Noctalia Greeter).

Installing the package **does not** change the greeter default. Cosmalia is installed and selectable; making it the default is a separate, explicit step.

---

## Stack

| Component | Role |
|-----------|------|
| `cosmic-comp` | Compositor (DRM/KMS, `--no-xwayland`) |
| `noctalia` | Bar, dock, launcher, notifications, lock, idle, MPRIS, polkit agent |
| `cosmalia-session` | Session launcher, XDG entry, dinit user services, greeter helper |
| `cosmic-settings-daemon` | Live theme/keybind changes via cosmic-config |
| `xdg-desktop-portal-cosmic` | File chooser, settings, access, remote desktop (screenshots/screencast disabled) |
| `polkit` + `gnome-keyring` | Polkit helper + Secret Service |

**Not included** - install separately if needed:
`xdg-desktop-portal-wlr` (it works better with OBS), `voxtype`, `syncthing`, `gvfs`, `polkit-gnome` (fallback agent).

---

## Files Installed

| Path | Purpose |
|------|---------|
| `/usr/bin/cosmalia-session` | Session launcher: starts compositor → finds Wayland socket → sets env → restarts portals → starts dinit target |
| `/usr/share/wayland-sessions/cosmalia.desktop` | XDG session entry (shown as **Cosmalia**) |
| `/usr/share/xdg-desktop-portal/cosmalia-portals.conf` | Portal selection: cosmic for FileChooser/settings/access/remote desktop; GTK fallback; screenshots/screencast disabled |
| `/etc/dinit.d/user/cosmalia-session.target` | Session target (internal), `depends-ms` on session services |
| `/etc/dinit.d/user/noctalia` | Noctalia service: `restart=on-failure`, `after: cosmic-settings-daemon` |
| `/etc/dinit.d/user/cosmic-settings-daemon` | Settings daemon service: `restart=on-failure` |
| `/usr/bin/cosmalia-session-default` | Opt-in helper to set gtkgreet default or add to dropdown |

---

## Install

**Recommended — package (pacman owns `/usr`):**

```sh
# From GitHub release
gh release download v1.2.3 -R grigio/cosmalia-session -p '*.pkg.tar.zst*' -D /tmp/cosmalia
cd /tmp/cosmalia && sha256sum -c ./*.pkg.tar.zst.sha256
sudo pacman -U ./*.pkg.tar.zst

# Or build locally from this checkout
makepkg -fi

# Optional: make it the greeter default
sudo cosmalia-session-default
```

**Building a local package**

The package is version-less in the source tree: `pkgver` and `pkgrel` are computed at build time from git tags and commit history. CI workflows (`.github/workflows/`) do this automatically.

```sh
# From a clean git checkout (pkgver from latest v* tag, pkgrel from commits touching packaging files)
makepkg -f

# Override version/release explicitly (e.g. for testing or CI)
SESSION_VERSION=1.2.3 SESSION_PKGREL=1 makepkg -f

# Install the resulting package
sudo pacman -U cosmalia-session-<pkgver>-<pkgrel>-any.pkg.tar.zst
```

The package uses `--nodeps` in CI because `cosmic-comp` is in the official repositories while other dependencies (noctalia, cosmic-settings, etc.) are not present in the build container. On a real system with all deps installed, `makepkg -fi` works without `--nodeps`.

**Without package (copies files directly):**

```sh
./scripts/install.sh                 # session files only
./scripts/install.sh --default       # ... and make it the default
```

> **Note:** The install script refuses to overwrite files owned by the `cosmalia-session-dinit` package. If the package is installed, rebuild it instead (`makepkg -fi`).

None of these edit `/etc/greetd` unless you pass `--default` or run `cosmalia-session-default`. Greeters reading `/usr/share/wayland-sessions` (Noctalia Greeter, GDM, SDDM) list Cosmalia immediately. For gtkgreet, add to dropdown without changing default:

```sh
sudo cosmalia-session-default --list
```

---

## What Runs

Started by the session (and supervised by dinit):

| Process | Notes |
|---------|-------|
| `cosmic-comp --no-xwayland` | Compositor; started by launcher, must run before socket exists |
| `noctalia` | Shell; dinit service, `restart=on-failure`, stopped when target stops |
| `cosmic-settings-daemon` | Config watchers; dinit service, same lifecycle |
| `xdg-desktop-portal` + `xdg-desktop-portal-cosmic` | Restarted per-login (cosmic backend has no stop-on-logout hook, survives logout with stale `WAYLAND_DISPLAY`) |

Already covered (no session entry needed):

- `dbus-broker` (user bus), `pipewire`/`wireplumber` (audio), `gnome-keyring-daemon` (Secret Service, PAM-unlocked at login), `gvfs-*`/`xdg-document-portal` (D-Bus activated), `upower`/`power-profiles-daemon`/`NetworkManager` (system services)

**Environment:** `XDG_CURRENT_DESKTOP=cosmalia:COSMIC` — the `:COSMIC` suffix selects the cosmic portal backend; `cosmalia` first makes `cosmalia-portals.conf` win.

### dinit Services

```
$ dinitctl --user list
[[+]     ] boot
[{+}     ] system
[{+}     ] dbus (pid: 739)
[[+]     ] login.target
[{+}     ] graphical.monitor (pid: 740)
[{+}     ] graphical.target
[[+]     ] cosmalia-session.target
[{+}     ] noctalia (pid: 790)
[{+}     ] cosmic-settings-daemon (pid: 789)
```

The session target (`cosmalia-session.target`) is an `internal` type with `depends-ms` on `noctalia` and `cosmic-settings-daemon`. Services do **not** depend back on the target — dinit would reject the cycle. Stopping the target stops the services automatically.

---

## Logs

```sh
tail -f "$XDG_RUNTIME_DIR/cosmalia-session.log"          # launcher + compositor
dinitctl --user catlog noctalia                           # shell (dumps log buffer)
dinitctl --user catlog cosmic-settings-daemon             # settings daemon (dumps log buffer)
```

The launcher/compositor log is truncated each login. Services log via dinit's log buffer (use `catlog` to view).

---

## Troubleshooting

| Issue | Check |
|-------|-------|
| Noctalia doesn't start | `dinitctl --user catlog noctalia`, `tail "$XDG_RUNTIME_DIR/cosmalia-session.log"`, `ss -xlp \| grep wayland` |
| Screenshots/screencast broken | Disabled by default (cosmic backend crashes on `ext_image_copy_capture_session_v1`). Install `xdg-desktop-portal-wlr` separately if needed. |
| File dialogs wrong/missing | `pacman -Q xdg-desktop-portal-cosmic`, `dinitctl --user status xdg-desktop-portal`, check `cosmalia-portals.conf` exists. A user config in `~/.config/xdg-desktop-portal/` overrides it. |
| "Failed to open service channel Wayland connection" | Expected and harmless (no Mutter service channel under cosmic-comp). |
| Traffic-light decorations missing | Ensure `cosmic-comp` package is installed (provides them). |
| Greeter doesn't default to Cosmalia | Intentional on install. Run `sudo cosmalia-session-default` or pick it once (Noctalia Greeter remembers). |
| Session log missing | `XDG_RUNTIME_DIR` must exist; launch from a logind login, not a bare console. |

---

## Reverting

```sh
# Restore previous greeter config (gtkgreet)
sudo cp -a /etc/greetd/config.toml.bak.<timestamp> /etc/greetd/config.toml
sudo cp -a /etc/greetd/environments.bak.<timestamp> /etc/greetd/environments

# Remove package
sudo pacman -R cosmalia-session-dinit

# Remove manual install (if not using package)
sudo rm /usr/share/wayland-sessions/cosmalia.desktop \
        /usr/bin/cosmalia-session \
        /usr/bin/cosmalia-session-default \
        /etc/dinit.d/user/cosmalia-session.target \
        /etc/dinit.d/user/noctalia \
        /etc/dinit.d/user/cosmic-settings-daemon \
        /usr/share/xdg-desktop-portal/cosmalia-portals.conf \
        /usr/share/doc/cosmalia-session-dinit/README.md \
        /usr/share/licenses/cosmalia-session-dinit/LICENSE
dinitctl --user reload

# Optionally remove compositor
sudo pacman -R cosmic-comp
```

Removing the package does not restore the greeter config; point the greeter elsewhere first (the `pre_remove` message reminds you).

---

## License

MIT — see [LICENSE](LICENSE).