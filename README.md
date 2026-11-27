# Cosmalia: Minimal COSMIC Desktop on dinit

![Cosmalia Desktop](./cosmalia-session-dinit.png)

**Cosmalia** is a minimal Wayland desktop built from:

- **cosmic-comp-traffic** - COSMIC Wayland compositor (traffic-light decorations, blur, animations, 3-finger swipes, in-process Alt+Tab)
- **Noctalia** - Shell: bar, dock, launcher, notifications, lock screen, idle/suspend, MPRIS, polkit agent

`cosmalia-session` is the opinionated XDG session that starts them together. It appears in any Wayland-capable login manager (like greetd).

Installing the package **does not** change the greeter default. Cosmalia is installed and selectable; making it the default is a separate, explicit step.

> **Which Cosmalia should I use?** This repository is the **dinit** variant. It
> runs on Artix Linux, needs no systemd, and works on older x86-64 hardware
> without the x86-64-v3 instruction set. If your computer is new, you want
> packages built for **x86-64-v3**, or you want **systemd**, use the
> [Arch Linux based cosmalia-session](https://github.com/grigio/cosmalia-session)
> instead. Same desktop, but with an Arch/CachyOS base, systemd and gtkgreet.

## Contents

- [Stack](#stack)
- [Files Installed](#files-installed)
- [Install](#install)
- [Live ISO](#live-iso)
- [What Runs](#what-runs)
- [Logs](#logs)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)
- [Reverting](#reverting)
- [License](#license)

---

## Stack

| Component | Role |
|-----------|------|
| `cosmic-comp-traffic` | Compositor (DRM/KMS, `--no-xwayland`) |
| `noctalia` | Bar, dock, launcher, notifications, lock, idle, MPRIS, polkit agent |
| `cosmalia-session` | Session launcher, XDG entry, dinit user services, greeter helper |
| `cosmic-settings-daemon` | Live theme/keybind changes via cosmic-config |
| `xdg-desktop-portal-cosmic` | File chooser, settings, access, remote desktop |
| `xdg-desktop-portal-wlr` | Screenshot/screen cast via `ext_image_copy_capture` (OBS screen capture) |
| `polkit` + `gnome-keyring` | Polkit daemon/agent helper + Secret Service |
| `xdg-desktop-portal-gtk` | Fallback portal backend for Print/Account/Email/etc. |

**Not included** (install separately if needed):
`voxtype`, `syncthing`, `gvfs`, `polkit-gnome` (fallback agent).

---

## Files Installed

| Path | Purpose |
|------|---------|
| `/usr/bin/cosmalia-session` | Session launcher: starts compositor → finds Wayland socket → sets env → restarts portals → starts dinit target |
| `/usr/share/wayland-sessions/cosmalia.desktop` | XDG session entry (shown as **Cosmalia**) |
| `/usr/share/xdg-desktop-portal/cosmalia-portals.conf` | Portal selection: cosmic for FileChooser/settings/access/remote desktop, wlr for ScreenCast/Screenshot (OBS), GTK fallback |
| `/etc/xdg/xdg-desktop-portal-wlr/cosmalia` | Screen capture without the broken interactive picker: captures `eDP-1` directly |
| `/etc/udev/rules.d/99-cosmalia-backlight.rules` | Backlight sysfs write access for the `video` group (brightness control) |
| `/etc/udev/rules.d/99-cosmalia-drm.rules` | Fallback `/dev/dri/*` access for the `video` group until elogind registers a seat |
| `/usr/share/polkit-1/rules.d/cosmalia-session.rules` | Polkit policy so local admins can change Wi-Fi networks |
| `/etc/dinit.d/user/cosmalia-session.target` | Session target (internal), `depends-ms` on session services |
| `/etc/dinit.d/user/noctalia` | Noctalia service: `restart=on-failure`, `after: cosmic-settings-daemon` |
| `/etc/dinit.d/user/cosmic-settings-daemon` | Settings daemon service: `restart=on-failure` |
| `/usr/bin/cosmalia-session-default` | Opt-in helper to set gtkgreet default or add to dropdown |

---

## Install

This package contains only scripts, services and configuration files
(`arch=any`). It runs on baseline x86-64 and makes no x86-64-v3 assumptions. See
the note at the top if you would rather use the systemd / x86-64-v3 build.

**Recommended: package (pacman owns `/usr`)**

```sh
# From the latest release of this repository
gh release download --repo grigio/cosmalia-session-dinit \
  -p 'cosmalia-session-dinit-*.pkg.tar.zst*' -D /tmp/cosmalia
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
SESSION_VERSION=1.6.3 SESSION_PKGREL=1 makepkg -f

# Install the resulting package
sudo pacman -U cosmalia-session-dinit-<pkgver>-<pkgrel>-any.pkg.tar.zst
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

## Live ISO

A ready-to-boot Artix/dinit live image is attached to every `v*` release tag
(current: **v1.6.3**). It contains only Artix packages and boots with dinit →
greetd/tuigreet → `cosmalia-session-dinit`. GRUB/syslinux offer two entries:
the normal boot and a safe `copytoram=y` fallback for USB sticks that stall.
Neither registers a serial console, which avoids hangs on bare-metal machines
without a working COM1.

```sh
gh release download v1.6.3 -R grigio/cosmalia-session-dinit -p '*.iso' -D /tmp/cosmalia-iso
# Replace /dev/sda with your stick; check with lsblk first.
sudo dd if=/tmp/cosmalia-iso/cosmalia-artix-dinit-*.iso of=/dev/sda \
     bs=1M status=progress conv=nocreat oflag=direct
sudo sync
```

The initramfs writes boot-stage markers to the console and to `BOOTLOG.TXT` on
the USB's `ARCHISO_EFI` partition, so a stall right after
`squashfs: version 4.0` can be attributed. See `iso/README.md` for details.

The live image also includes an **offline Calamares installer** ("Install
Cosmalia" in the app menu): it copies the running live environment to disk and
sets up **Limine** + **dinit** (including `cosmalia-session-dinit`) on the
installed system. No network or package downloads are needed. The VM test
(`iso/test-installer.sh`, `iso/installer-drive.py`, `iso/test-installed.sh`)
drives the wizard and boots the installed disk to verify it.

---

## What Runs

Started by the session (and supervised by dinit):

| Process | Notes |
|---------|-------|
| `cosmic-comp --no-xwayland` | Compositor from the `cosmic-comp-traffic` fork (the binary is named `cosmic-comp`); started by the launcher, must run before the socket exists |
| `noctalia` | Shell; dinit service, `restart=on-failure`, stopped when target stops |
| `cosmic-settings-daemon` | Config watchers; dinit service, same lifecycle |
| `xdg-desktop-portal` + `xdg-desktop-portal-cosmic` | Restarted per-login (cosmic backend has no stop-on-logout hook, survives logout with stale `WAYLAND_DISPLAY`) |

Already covered (no session entry needed):

- `dbus-daemon` (user bus), `pipewire`/`wireplumber` (audio), `gnome-keyring-daemon` (Secret Service, PAM-unlocked at login), `gvfs-*`/`xdg-document-portal` (D-Bus activated), `upower`/`power-profiles-daemon`/`NetworkManager` (system services)

**Environment:** `XDG_CURRENT_DESKTOP=cosmalia:COSMIC`. The `:COSMIC` suffix selects the cosmic portal backend, while putting `cosmalia` first makes `cosmalia-portals.conf` win.

### Permissions that the session needs

- **Brightness:** Noctalia writes `/sys/class/backlight/*/brightness` itself. A
  minimal elogind setup only tags backlights with `seat`, leaving the sysfs
  file `root:root 0644`, so the widget reports "brightness control
  unavailable". The installed udev rule gives the `video` group write access;
  your user must be in `video` (check with `id`). `post_install` triggers udev
  so it works without a reboot.
- **Polkit:** `polkitd` is a system service and Noctalia's built-in agent is
  enabled by default (`shell.polkit_agent = true`). Under dinit the user
  services run in a `user-1000.userspawn` cgroup, *not* in the logind session
  cgroup, so polkit reports `subject.local/active` as false and the agent
  cannot register ("Cannot determine session the caller is in"). The launcher
  therefore passes `XDG_SESSION_ID`/`XDG_SESSION_CLASS` to the user manager
  and the D-Bus activation environment (fixes lock/idle integration), and the
  shipped rule authorises NetworkManager by **group** instead of by locality.
  Verify with `pkcheck --action-id org.freedesktop.NetworkManager.settings.modify.system --process $$`.
- **NetworkManager:** the installed polkit rule lets members of `wheel` (or
  `sudo`) change Wi-Fi connections without waiting on an authentication
  agent. This is what makes Noctalia's network widget able to switch networks
  without a "Not authorized to control networking" error.
- **Keyring:** Noctalia reads its encrypted storage key from the Secret
  Service at startup. If the `login` keyring's password does not match the
  account password (e.g. the account password was changed later), PAM cannot
  unlock it and a keyring prompt appears on every login. SDDM's PAM stack
  already includes `pam_gnome_keyring.so`; make sure the keyring password
  matches the login password. To recreate the keyring from scratch (losing
  stored secrets), stop `gnome-keyring-daemon`, move
  `~/.local/share/keyrings/login.keyring` aside and log in again.
- **xdg-portal:** the portals are D-Bus activated (there are no dinit units for
  them). The launcher publishes `WAYLAND_DISPLAY` in the D-Bus activation
  environment and stops stale portal processes from a previous login so D-Bus
  starts fresh ones. `cosmalia-portals.conf` pins all COSMIC interfaces and
  uses the GTK backend as fallback, hence the `xdg-desktop-portal-gtk`
  dependency.

### dinit Services

```
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

The system manager runs `boot` → `system` → `login.target`, with `greetd`,
`dbus`, `NetworkManager` and a serial getty enabled in `/etc/dinit.d/boot.d/`.

The session target (`cosmalia-session.target`) is an `internal` type with `depends-ms` on `noctalia` and `cosmic-settings-daemon`. Services do **not** depend back on the target: dinit would reject the cycle. Stopping the target stops the services automatically.

---

## Logs

```sh
tail -f "$XDG_RUNTIME_DIR/cosmalia-session.log"          # launcher + compositor
dinitctl --user catlog noctalia                           # shell (dumps log buffer)
dinitctl --user catlog cosmic-settings-daemon             # settings daemon (dumps log buffer)
```

The launcher/compositor log is truncated each login. Services log via dinit's log buffer (use `catlog` to view).

---

## FAQ

**Q: Does hybrid tiling work?**

Yes. Press `SUPER + Y` to toggle hybrid tiling.

**Q: Can I use `cosmic-comp` instead of `cosmic-comp-traffic`?**

No. `cosmic-comp-traffic` is a fork with improvements and Wayland integrations
that upstream `cosmic-comp` does not have (traffic-light decorations, blur,
animations, 3-finger swipes, in-process Alt+Tab — see [Stack](#stack)). Note
that the binary is called `cosmic-comp` either way; the choice is which package
provides it. You can swap in the upstream compositor if you insist, and it
works, but it is limited: those extras will be missing.

**Q: Do I have to use Cosmic Settings or Noctalia settings?**

Both. They are complementary, not alternatives — some features are managed by
one UI and others by the other. Window/compositor behaviour and keyboard
shortcuts live in **Cosmic Settings**, while the shell — bar, dock, launcher,
notifications, lock screen and idle/suspend — is configured in **Noctalia
settings**.

---

## Troubleshooting

| Issue | Check |
|-------|-------|
| Noctalia doesn't start | `dinitctl --user catlog noctalia`, `tail "$XDG_RUNTIME_DIR/cosmalia-session.log"`, `ss -xlp \| grep wayland` |
| Brightness control unavailable | `id` (must include `video`), `ls -l /sys/class/backlight/*/brightness` (must be `root:video 664`), `udevadm trigger --subsystem-match=backlight --action=add` |
| Cannot switch Wi-Fi network | `pkcheck --action-id org.freedesktop.NetworkManager.settings.modify.system --process $$`, `id` (must include `wheel`), check `/usr/share/polkit-1/rules.d/cosmalia-session.rules` |
| Portal backends not starting | `XDG_CURRENT_DESKTOP=cosmalia:COSMIC /usr/lib/xdg-desktop-portal -v -r`, `pacman -Q xdg-desktop-portal-gtk xdg-desktop-portal-cosmic` |
| No "Screen Capture (PipeWire)" source in OBS | `pacman -Q xdg-desktop-portal-wlr`, check `cosmalia-portals.conf` has `ScreenCast=wlr`, then restart xdg-desktop-portal and OBS. The cosmic backend crashes on `ext_image_copy_capture_session_v1`, so wlr must serve ScreenCast. |
| Screen capture selector is cancelled immediately | cosmic-comp's interactive capture picker does not work with xdg-desktop-portal-wlr. The shipped `/etc/xdg/xdg-desktop-portal-wlr/cosmalia` sets `chooser_type=none` and `output_name=eDP-1`, so capture starts without a picker. Change `output_name` if your display is not `eDP-1` (see `wayland-info`). |
| File dialogs wrong/missing | `pacman -Q xdg-desktop-portal-cosmic xdg-desktop-portal-gtk`, `XDG_CURRENT_DESKTOP=cosmalia:COSMIC /usr/lib/xdg-desktop-portal -v -r`, check `cosmalia-portals.conf` exists. A user config in `~/.config/xdg-desktop-portal/` overrides it. |
| Black screen on real AMD/Intel hardware (live ISO) | Read `/run/user/1000/cosmalia-session.log`; on the live ISO the launcher copies it to `SESSIONLOG.TXT` on the USB's FAT partition, where the initramfs also writes `BOOTLOG.TXT`. The launcher waits for a real DRM card and skips `simpledrm` cards via `COSMIC_DRM_BLOCK_DEVICES`. If boot stalls earlier, the last `cosmalia:` console marker identifies the stage; see `iso/README.md`. |
| "Failed to open service channel Wayland connection" | Expected and harmless (no Mutter service channel under cosmic-comp). |
| Traffic-light decorations missing | They come from the `cosmic-comp-traffic` fork, which provides `/usr/bin/cosmic-comp` (`pacman -Q cosmic-comp-traffic`). Upstream `cosmic-comp` does not include them — see the [FAQ](#faq). |
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
        /usr/share/licenses/cosmalia-session-dinit/LICENSE \
        /usr/share/polkit-1/rules.d/cosmalia-session.rules \
        /etc/udev/rules.d/99-cosmalia-backlight.rules \
        /etc/udev/rules.d/99-cosmalia-drm.rules
# `reload` needs a service name in this dinit version; new services are
# discovered on demand, so this is only needed if they are still loaded.
dinitctl --user reload cosmalia-session.target 2>/dev/null || true

# Optionally remove compositor
sudo pacman -R cosmic-comp
```

Removing the package does not restore the greeter config; point the greeter elsewhere first (the `pre_remove` message reminds you).

---

## License

MIT. See [LICENSE](LICENSE).
