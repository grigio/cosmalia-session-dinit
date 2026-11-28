# Cosmalia. Modern Minimal Linux Desktop under 400Mb Ram on dinit

![Cosmalia Desktop](./cosmalia-session-dinit.png)

**Cosmalia** is built from these components:

- [cosmic-comp-traffic](https://github.com/grigio/cosmic-comp-traffic) - COSMIC Wayland compositor (traffic-light decorations, blur, animations, 3-finger swipes, in-process Alt+Tab)
- [noctalia](https://github.com/noctalia-dev/noctalia) - Shell: bar, dock, launcher, notifications, lock screen, idle/suspend, MPRIS, polkit agent
- [dinit](https://github.com/davmac314/dinit) - minimal init system
- [artix linux](https://artixlinux.org/) - a minimal systemd-free archlinux (also archlinux/cachyos systemd is supported, use [cosmalia-session](https://github.com/grigio/cosmalia-session) instead)

`cosmalia-session` is the opinionated XDG session that starts them together. It appears in any Wayland-capable login manager (like greetd). You can install Cosmalia in Artix Linux or try/install Cosmalia via Live ISO attached in the [releases](https://github.com/grigio/cosmalia-session-dinit/releases).

## Contents

- [Stack](#stack)
- [Install](#install)
- [Live ISO](#live-iso)
- [Files Installed](#files-installed)
- [Session & services](#session--services)
- [Troubleshooting & FAQ](#troubleshooting--faq)
- [Reverting](#reverting)
- [License](#license)

---

## Stack

| Component | Role |
|-----------|------|
| `cosmic-comp-traffic` | Compositor (DRM/KMS, `--no-xwayland`); provides `/usr/bin/cosmic-comp` |
| `noctalia` | Bar, dock, launcher, notifications, lock, idle, MPRIS, polkit agent |
| `cosmic-settings-daemon` | Live theme/keybind changes via cosmic-config |
| `xdg-desktop-portal-cosmic` | File chooser, settings, access, remote desktop |
| `xdg-desktop-portal-wlr` | Screenshot/screen cast via `ext_image_copy_capture` (OBS) |
| `xdg-desktop-portal-gtk` | Fallback for Print/Account/Email/etc. |
| `polkit` + `gnome-keyring` | Polkit daemon/agent + Secret Service |
| `cosmalia-session` | Launcher, XDG entry, dinit user services, greeter helper |

Not included (install separately if needed): `voxtype`, `syncthing`, `gvfs`, `polkit-gnome`.

The session exports `XDG_CURRENT_DESKTOP=cosmalia:COSMIC`: the `:COSMIC` suffix selects the cosmic portal backend, while putting `cosmalia` first makes `cosmalia-portals.conf` win.

---

## Install

The package is `arch=any` (scripts, services and config only) and runs on baseline x86-64 — no x86-64-v3 assumptions. For the systemd / x86-64-v3 build use [cosmalia-session](https://github.com/grigio/cosmalia-session).

**Package (recommended — pacman owns `/usr`):**

```sh
gh release download --repo grigio/cosmalia-session-dinit \
  -p 'cosmalia-session-dinit-*.pkg.tar.zst*' -D /tmp/cosmalia
cd /tmp/cosmalia && sha256sum -c ./*.pkg.tar.zst.sha256
sudo pacman -U ./*.pkg.tar.zst
```

Or build locally with `makepkg -fi`. The package is version-less in the source tree: `pkgver`/`pkgrel` are computed from git tags and commit history (override with `SESSION_VERSION=1.6.3 SESSION_PKGREL=1 makepkg -f`). CI uses `--nodeps` because some dependencies are absent from the build container; on a system with all deps installed `makepkg -fi` works without it.

**Without a package:** `./scripts/install.sh` copies the files directly (`--default` also sets the greeter default). The script refuses to overwrite files owned by the package — rebuild it instead.

Nothing edits `/etc/greetd` unless you pass `--default` or run `sudo cosmalia-session-default`. Greeters reading `/usr/share/wayland-sessions` (Noctalia Greeter, GDM, SDDM) list Cosmalia immediately. For gtkgreet, add it to the dropdown without changing the default: `sudo cosmalia-session-default --list`.

---

## Live ISO

A ready-to-boot Artix/dinit live image is attached to every `v*` release (current: **v1.6.3**). It boots dinit → greetd/tuigreet → `cosmalia-session-dinit` using only Artix packages. GRUB/syslinux offer a normal entry and a safe `copytoram=y` fallback for slow USB sticks; neither registers a serial console (avoids bare-metal hangs).

```sh
gh release download v1.6.3 -R grigio/cosmalia-session-dinit -p '*.iso' -D /tmp/cosmalia-iso
# Replace /dev/sda with your stick; check with lsblk first.
sudo dd if=/tmp/cosmalia-iso/cosmalia-artix-dinit-*.iso of=/dev/sda \
     bs=1M status=progress conv=nocreat oflag=direct
sudo sync
```

Boot stages print `cosmalia:` markers to the console and to `BOOTLOG.TXT` on the `ARCHISO_EFI` partition, so a stall after `squashfs: version 4.0` can be pinpointed. The image also ships an offline Calamares installer ("Install Cosmalia") that copies the live environment to disk and sets up Limine + dinit. See `iso/README.md`.

---

## Files Installed

| Path | Purpose |
|------|---------|
| `/usr/bin/cosmalia-session` | Launcher: compositor → Wayland socket → env → restart portals → start dinit target |
| `/usr/share/wayland-sessions/cosmalia.desktop` | XDG session entry (**Cosmalia**) |
| `/usr/share/xdg-desktop-portal/cosmalia-portals.conf` | Portal routing: cosmic for FileChooser/settings/access/remote desktop, wlr for ScreenCast/Screenshot, GTK fallback |
| `/etc/xdg/xdg-desktop-portal-wlr/cosmalia` | Screen capture without the broken picker: `chooser_type=none`, fixed `output_name` |
| `/etc/udev/rules.d/99-cosmalia-backlight.rules` | Backlight write access for the `video` group |
| `/etc/udev/rules.d/99-cosmalia-drm.rules` | `/dev/dri/*` access for `video` until elogind registers a seat |
| `/usr/share/polkit-1/rules.d/cosmalia-session.rules` | Lets local admins change Wi-Fi |
| `/etc/dinit.d/user/cosmalia-session.target` | Session target (internal), `depends-ms` on the services below |
| `/etc/dinit.d/user/noctalia` | Noctalia service (`restart=on-failure`) |
| `/etc/dinit.d/user/cosmic-settings-daemon` | Settings daemon (`restart=on-failure`) |
| `/usr/bin/cosmalia-session-default` | Opt-in greeter default helper |

---

## Session & services

Started by the launcher / supervised by dinit:

| Process | Notes |
|---------|-------|
| `cosmic-comp --no-xwayland` | Compositor (`cosmic-comp-traffic` fork); started by the launcher before the socket exists |
| `noctalia` | Shell; dinit service, stopped when the target stops |
| `cosmic-settings-daemon` | Config watchers; same lifecycle |
| `xdg-desktop-portal` + `xdg-desktop-portal-cosmic` | Restarted per login (the cosmic backend has no stop-on-logout hook and keeps a stale `WAYLAND_DISPLAY`) |

Already covered, no session entry needed: `dbus-daemon` (user bus), `pipewire`/`wireplumber`, `gnome-keyring-daemon` (Secret Service, PAM-unlocked), `gvfs-*`/`xdg-document-portal`, `upower`/`power-profiles-daemon`/`NetworkManager` (system services).

Portals are **D-Bus activated**, not dinit units. The launcher publishes `WAYLAND_DISPLAY` in the D-Bus activation environment and kills stale portals from previous logins. Via `dinitctl --user setenv` it also passes `WAYLAND_DISPLAY`, `XDG_CURRENT_DESKTOP`, `XDG_SESSION_TYPE`, `XDG_SESSION_DESKTOP`, `XDG_SESSION_ID`, `XDG_SESSION_CLASS`, `DESKTOP_SESSION`, `XDG_RUNTIME_DIR` and `PATH` — without `XDG_SESSION_ID`, Noctalia's lock/idle monitoring breaks.

```sh
$ dinitctl --user list
[[+]     ] boot
[{+}     ] dbus
[{+}     ] pipewire
[{+}     ] pipewire-pulse
[{+}     ] wireplumber
[[+]     ] cosmalia-session.target
[{+}     ] noctalia
[{+}     ] cosmic-settings-daemon
```

The target is `internal` with `depends-ms` on `noctalia` and `cosmic-settings-daemon`. Services do **not** depend back on it — dinit rejects the cycle; stopping the target stops them. The system manager runs `boot` → `system` → `login.target`, with `greetd`, `dbus`, `NetworkManager` and a serial getty in `/etc/dinit.d/boot.d/`.

**Permissions to be aware of:**

- **Brightness:** Noctalia writes the backlight sysfs directly; the udev rule grants the `video` group write access (your user must be in `video`).
- **Polkit / NetworkManager:** under dinit, user services live in `user-1000.userspawn`, not the logind session cgroup, so polkit cannot rely on locality. The shipped rule authorises `wheel`/`sudo` by group; Noctalia's agent is on by default (`shell.polkit_agent = true`).
- **Keyring:** Noctalia reads its storage key from the Secret Service at login. If the `login` keyring password differs from the account password, PAM cannot unlock it and a prompt appears every login.

---

## Troubleshooting & FAQ

**Logs**

```sh
tail -f "$XDG_RUNTIME_DIR/cosmalia-session.log"   # launcher + compositor (truncated each login)
dinitctl --user catlog noctalia                   # shell
dinitctl --user catlog cosmic-settings-daemon     # settings daemon
```

**FAQ**

- **Hybrid tiling?** Yes — `SUPER + Y`.
- **Use upstream `cosmic-comp` instead?** It works but lacks the fork's extras (traffic-light decorations, blur, animations, 3-finger swipes, in-process Alt+Tab). The binary is called `cosmic-comp` either way; the choice is which package provides it.
- **Cosmic Settings or Noctalia settings?** Both — complementary. Window/compositor behaviour and keyboard shortcuts live in Cosmic Settings; bar, dock, launcher, notifications, lock and idle live in Noctalia settings.

<details>
<summary>Common issues</summary>

| Issue | Check |
|-------|-------|
| Noctalia doesn't start | `dinitctl --user catlog noctalia`, `tail "$XDG_RUNTIME_DIR/cosmalia-session.log"`, `ss -xlp \| grep wayland` |
| Brightness unavailable | `id` (needs `video`), `ls -l /sys/class/backlight/*/brightness` (should be `root:video 664`), `udevadm trigger --subsystem-match=backlight --action=add` |
| Cannot switch Wi-Fi | `pkcheck --action-id org.freedesktop.NetworkManager.settings.modify.system --process $$`, `id` (needs `wheel`) |
| Portal backends not starting | `XDG_CURRENT_DESKTOP=cosmalia:COSMIC /usr/lib/xdg-desktop-portal -v -r`, `pacman -Q xdg-desktop-portal-gtk xdg-desktop-portal-cosmic` |
| No "Screen Capture (PipeWire)" in OBS | `pacman -Q xdg-desktop-portal-wlr`, ensure `ScreenCast=wlr` in `cosmalia-portals.conf`, then restart portal + OBS (cosmic backend crashes on `ext_image_copy_capture_session_v1`) |
| Capture picker cancelled immediately | cosmic-comp's picker is incompatible with portal-wlr; `chooser_type=none` and `output_name=eDP-1` are shipped — change `output_name` for other displays (`wayland-info`) |
| File dialogs wrong/missing | `pacman -Q xdg-desktop-portal-cosmic xdg-desktop-portal-gtk`, re-run the portal check; a user config in `~/.config/xdg-desktop-portal/` overrides the shipped one |
| Black screen on real hardware (live ISO) | Read `/run/user/1000/cosmalia-session.log` (copied to `SESSIONLOG.TXT` on the USB FAT partition); the launcher waits for a real DRM card and skips `simpledrm` via `COSMIC_DRM_BLOCK_DEVICES`; check the last `cosmalia:` console marker |
| "Failed to open service channel Wayland connection" | Harmless — no Mutter service channel under cosmic-comp |
| Traffic-light decorations missing | From `cosmic-comp-traffic` (`pacman -Q cosmic-comp-traffic`); upstream lacks them |
| Greeter doesn't default to Cosmalia | Intentional — `sudo cosmalia-session-default` or pick it once (Noctalia Greeter remembers) |
| Session log missing | `XDG_RUNTIME_DIR` must exist; launch from a logind login, not a bare console |

</details>

---

## Reverting

<details>
<summary>Click to expand</summary>

```sh
# Restore previous gtkgreet config
sudo cp -a /etc/greetd/config.toml.bak.<timestamp> /etc/greetd/config.toml
sudo cp -a /etc/greetd/environments.bak.<timestamp> /etc/greetd/environments

# Remove package
sudo pacman -R cosmalia-session-dinit

# Or remove a manual install
sudo rm /usr/share/wayland-sessions/cosmalia.desktop \
        /usr/bin/cosmalia-session /usr/bin/cosmalia-session-default \
        /etc/dinit.d/user/cosmalia-session.target \
        /etc/dinit.d/user/noctalia /etc/dinit.d/user/cosmic-settings-daemon \
        /usr/share/xdg-desktop-portal/cosmalia-portals.conf \
        /usr/share/doc/cosmalia-session-dinit/README.md \
        /usr/share/licenses/cosmalia-session-dinit/LICENSE \
        /usr/share/polkit-1/rules.d/cosmalia-session.rules \
        /etc/udev/rules.d/99-cosmalia-backlight.rules \
        /etc/udev/rules.d/99-cosmalia-drm.rules
# `reload` needs a service name in this dinit version; new services load on demand.
dinitctl --user reload cosmalia-session.target 2>/dev/null || true

# Optionally remove compositor
sudo pacman -R cosmic-comp
```

Removing the package does not restore the greeter config — point the greeter elsewhere first.

</details>

---

## License

MIT. See [LICENSE](LICENSE).
