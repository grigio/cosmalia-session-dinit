# Cosmalia live ISO (Artix Linux / dinit)

Self-contained build project, kept in `/tmp/opencode/cosmalia-session-dinit-iso`
so the `cosmalia-session-dinit` checkout stays clean (no uncommitted files
spread through it). It builds the package from `SESSION_SRC_DIR`, defaulting
to `~/Code/cosmalia-session-dinit`; all generated files (`local-repo/`, `out/`,
`test-results/`) stay here. `build.sh` refuses to write into `SRC_DIR`, so no
generated or root-owned files can appear in the checkout.

A minimal **Artix Linux** live ISO that boots with **dinit** (no systemd) and
drops straight into the Cosmalia desktop (`cosmic-comp` + Noctalia). The login
manager is **greetd with tuigreet**, a textual TUI greeter on the VT — no cage,
no GTK greeter. `initial_session` autologins `liveuser` into Cosmalia; logging
out returns to tuigreet.

This is the dinit counterpart of [`cosmalia-session/iso`](https://github.com/grigio/cosmalia-session/tree/master/iso),
which is based on CachyOS + systemd + gtkgreet.

## What is in it

- Artix `system` / `world` / `galaxy` repos plus Arch **`extra`** only
  (`core` is *not* enabled: its systemd packages would replace dinit).
- Mainline Artix `linux` kernel, archiso initramfs (`archiso` + `archiso_loop_mnt`
  hooks from `mkinitcpio-archiso`), Intel/AMD microcode, GRUB (UEFI) +
  syslinux (BIOS).
- `dinit`, `userspawn-dinit` (per-user dinit manager), `elogind-dinit`,
  `dbus-dinit` + `dbus-dinit-user`, `greetd` + `greetd-dinit` + `greetd-tuigreet`.
- `cosmalia-session-dinit` built from this checkout and `cosmic-comp-traffic`
  from the pinned `epoch-1.12.0-rc.1` release, both served from a local pacman
  repository; `noctalia`, portals, pipewire, polkit, NetworkManager, Alacritty
  and Octopi come from the repos. The release package's `systemd-libs`
  dependency is rewritten to `libelogind` at build time (see below).
- **Browser:** `brave-origin` / `brave-origin-bin` is not in Artix. `build.sh`
  probes the configured repositories and uses **`chromium`** (Arch `extra`)
  when Brave is unavailable, falling back to `ungoogled-chromium` for
  Artix-only mirrors. The chosen package is written into `packages.x86_64` and
  pinned in the Noctalia dock. Override with `COSMALIA_BROWSER=<pkg>`.
- Trimmed: no docs/man/locale via `NoExtract`, zstd squashfs level 15, no
  KDE/GNOME/Calamares, buggy cosmic portal + keyring prompter disabled with
  D-Bus `/usr/bin/true` stubs. Screenshots use grim|satty + the wlr portal.

## Build

Host packages: `archiso`, `mkinitcpio`, `squashfs-tools`, `grub`, `syslinux`,
`dosfstools`, `mtools`, `libisoburn`, `base-devel` (`makepkg`, `repo-add`).

```sh
cd /tmp/opencode/cosmalia-session-dinit-iso
SESSION_SRC_DIR=~/Code/cosmalia-session-dinit ./build.sh
```

Outputs:

- `out/cosmalia-artix-dinit-<version>-x86_64.iso`
- `local-repo/` — local pacman repository with `cosmalia-session-dinit`

Nothing is installed on the host: only `mkarchiso` runs via `sudo`. `build.sh`
works on a copy of `profile/` in `/tmp/opencode/cosmalia-artix-dinit-iso-work`
and wipes it first (mkarchiso's `_run_once` markers otherwise reuse stale
artifacts). Environment overrides: `ISO_REPO_DIR`, `ISO_OUT_DIR`,
`ISO_WORK_DIR`, `COSMALIA_BROWSER`.

The **build-time** pacman.conf uses `SigLevel = Optional TrustAll`: a build
host that is not Artix does not trust Artix signing keys, so pacstrap would
otherwise reject every Artix package. Downloads still come from HTTPS official
mirrors. The **live image** keeps `SigLevel = Required DatabaseOptional` and
`customize_airootfs.sh` initialises and populates the `artix` + `archlinux`
keyrings inside the chroot, so `pacman -Syu` verifies signatures normally.

A build host with a newer libalpm writes `%INSTALLED_DB%` into every local
package database record; the Artix pacman in the image warns on every call.
`customize_airootfs.sh` strips that key from `/var/lib/pacman/local/*/desc`.

`cosmic-comp-traffic` is downloaded from the pinned release into `packages/`
(override with `COSMIC_COMP_PKG`). Its `.PKGINFO` dependency `systemd-libs` is
rewritten to `libelogind`: Artix has no `systemd-libs`, and the compositor has
no direct `libsystemd` need — its `libseat` is linked against `libelogind` on
Artix. `COSMIC_COMP_TAG` overrides the release tag.

## Test in QEMU

```sh
./test.sh
```

Boots with KVM, OVMF (UEFI), QXL graphics and a serial console. `qemu-probe.py`
logs in on `ttyS0`, runs dinit/pacman/network checks inside the guest, captures
desktop / tuigreet / re-login screenshots, and writes `test-results/report.txt`.
For an interactive window with host internet via a TAP + dnsmasq + nftables
masquerade, use `./run.sh`.

## dinit notes specific to this image

- `boot` → `system` → `login.target` are provided by `dinit-rc`. Services are
  **enabled with symlinks in `/etc/dinit.d/boot.d/`**; `customize_airootfs.sh`
  enables `dbus`, `NetworkManager` and `greetd` there.
- `greetd` has `depends-on = login.target` and `options = runs-on-console`.
  The default `getty` on `tty1` is removed (`/usr/lib/dinit.d/boot.d/agetty`)
  to avoid fighting greetd for the VT; a standalone `serial-getty-ttyS0` is
  enabled instead for serial access. No `@` in the name: dinit treats it as a
  template/instance separator and refuses to load such a service file.
- The user D-Bus bus comes from `dbus-dinit-user`
  (`/etc/dinit.d/user/dbus`), the per-user dinit manager from `userspawn`.
  `userspawnrc` copies its own `boot`/`boot.d` into `~/.config/dinit.d`, so
  the live user's skel ships `~/.config/dinit.d/boot.d/` symlinks enabling
  `dbus`, `pipewire`, `pipewire-pulse` and `wireplumber`. This is what lets
  `cosmalia-session` call `dinitctl --user` and publish the activation
  environment.
- The initramfs drop-in loads `loop` and `dm-snapshot` in `MODULES=()`. Without
  them the `archiso` hook cannot allocate a loop device for `airootfs.sfs`
  and boot drops to the initramfs rescue shell.
- `pam_securetty.so` is removed from `/etc/pam.d/greetd`: greetd has no
  `PAM_TTY`, so autologin would otherwise silently fall back to the greeter.
- `elogind` replaces `systemd-logind`; a drop-in ignores suspend/lid events.

## Layout

```
cosmalia-session-dinit-iso/   # /tmp/opencode/, outside the git checkout
├── build.sh          # builds the local package + the ISO
├── test.sh           # headless QEMU verification (evidence in test-results/)
├── run.sh            # interactive QEMU with host internet
├── qemu-probe.py     # serial-console + HMP probe used by test.sh
├── profile/
│   ├── profiledef.sh
│   ├── packages.x86_64
│   ├── pacman.conf                # template; @REPO_DIR@ substituted by build.sh
│   ├── mirrorlist-artix
│   ├── mirrorlist-arch
│   ├── grub/grub.cfg
│   ├── syslinux/*.cfg
│   └── airootfs/                 # copied into the image before pacstrap
└── out/              # generated ISOs
```
