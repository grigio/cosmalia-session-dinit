# Cosmalia live ISO (Artix Linux / dinit)

Self-contained build project, kept in `/tmp/opencode/cosmalia-session-dinit-iso`
so the `cosmalia-session-dinit` checkout stays clean (no uncommitted files
spread through it). It builds the package from `SESSION_SRC_DIR`, defaulting
to `~/Code/cosmalia-session-dinit`. Build scratch (`local-repo/`, mkarchiso
work dir) stays outside the checkout, but the finished ISO goes to the
**project's `iso/out/`** (gitignored, and chowned back to the invoking user).
`build.sh` refuses to put packages or scratch anywhere inside `SRC_DIR`.

A minimal **Artix Linux** live ISO that boots with **dinit** (no systemd) and
drops straight into the Cosmalia desktop (`cosmic-comp` + Noctalia). The login
manager is **greetd with tuigreet**, a textual TUI greeter on the VT — no cage,
no GTK greeter. `initial_session` autologins `liveuser` into Cosmalia; logging
out returns to tuigreet.

This is the dinit counterpart of [`cosmalia-session/iso`](https://github.com/grigio/cosmalia-session/tree/master/iso),
which is based on CachyOS + systemd + gtkgreet.

## What is in it

- Artix `system` / `world` / `galaxy` repos only, plus local `[cosmalia]`. No
  Arch repositories or packages; `mkarchiso` is vendored in `iso/tools/`.
- Mainline Artix `linux` kernel, vendored Artix live initramfs hooks, Intel/AMD
  microcode, **GRUB (UEFI)** + syslinux (BIOS).
- `dinit`, `userspawn-dinit` (per-user dinit manager), `elogind-dinit`,
  `dbus-dinit` + `dbus-dinit-user`, `greetd` + `greetd-dinit` + `greetd-tuigreet`.
- `cosmalia-session-dinit` built from this checkout and `cosmic-comp-traffic`
  from the pinned `epoch-1.12.0-rc.1` release, both served from a local pacman
  repository; `noctalia`, portals, pipewire, polkit, NetworkManager, Alacritty
  and Octopi come from the repos. The release package's `systemd-libs`
  dependency is rewritten to `libelogind` at build time (see below).
- **Browser:** `ungoogled-chromium` from Artix galaxy (fallback `firefox`).
  The chosen package is written into `packages.x86_64` and pinned in the
  Noctalia dock. Override with `COSMALIA_BROWSER=<pkg>`.
- Trimmed: no docs/man/locale via `NoExtract`, zstd squashfs level 15, no
  KDE/GNOME/Calamares, buggy cosmic portal + keyring prompter disabled with
  D-Bus `/usr/bin/true` stubs. Screenshots use grim|satty + the wlr portal.

## Build

Host packages: `archiso`, `mkinitcpio`, `squashfs-tools`, `grub`, `syslinux`,
`dosfstools`, `mtools`, `libisoburn`, `base-devel` (`makepkg`, `repo-add`).

```sh
cd ~/Code/cosmalia-session-dinit/iso
SESSION_SRC_DIR=~/Code/cosmalia-session-dinit ./build.sh
```

Outputs:

- `~/Code/cosmalia-session-dinit/iso/out/cosmalia-artix-dinit-<version>-x86_64.iso`
  — lives **in the project** and is gitignored (`/iso/out/`). mkarchiso writes
  it as root; `build.sh` chowns it back to you.
- `<ISO_REPO_DIR>` — local pacman repository with `cosmalia-session-dinit`
  (default `/tmp/opencode/cosmalia-session-dinit-iso/local-repo`)

Nothing is installed on the host: only `mkarchiso` runs via `sudo`. `build.sh`
works on a copy of `profile/` in `ISO_WORK_DIR` and wipes it first (mkarchiso's
`_run_once` markers otherwise reuse stale artifacts). Environment overrides:
`ISO_REPO_DIR`, `ISO_OUT_DIR`, `ISO_WORK_DIR`, `COSMALIA_BROWSER`.

The **build-time** pacman.conf uses `SigLevel = Optional TrustAll`: a build
host that is not Artix does not trust Artix signing keys, so pacstrap would
otherwise reject every Artix package. Downloads still come from HTTPS official
mirrors. The **live image** keeps `SigLevel = Required DatabaseOptional` and
`customize_airootfs.sh` initialises and populates the Artix keyring inside the
chroot, so `pacman -Syu` verifies signatures normally.

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
Both `test.sh` and `run.sh` find the newest ISO in the project's `iso/out/`
(or their own `out/` from older builds). For an interactive window with host
internet via a TAP + dnsmasq + nftables masquerade, use `./run.sh`.

## Real hardware (AMD/Intel): black screen after the boot loader

QEMU uses QXL, whose DRM driver is present immediately and needs no firmware.
On a physical machine the compositor starts while `i915`/`xe`/`amdgpu` are
still being loaded by udev, and the kernel's built-in `simpledrm` owns the EFI
framebuffer as `/dev/dri/card0`. cosmic-comp then draws to that card, which is
not connected to the panel — the result is a black screen even though dinit,
greetd and Noctalia are all running. Fixes shipped in this image:

- `cosmalia-session` waits for a DRM card with a real driver, then exports
  `COSMIC_DRM_BLOCK_DEVICES` for every `simpledrm` card still present. It uses
  both the `cardN` name and the `major:minor` from `/sys/class/drm/cardN/dev` —
  cosmic-comp resolves the blocklist against render nodes, so a bare `cardN`
  can silently fail to match. It retries the compositor if the driver is late.
- The initramfs hook overrides archiso's root overlay mount with
  `uuid=off,xino=off,index=off,metacopy=off`. Kernel 7.x enables those overlayfs
  features by default; on real hardware the boot stalled right after the
  `overlayfs: "xino" feature enabled` message. A live RAM overlay needs none
  of them.
- `mesa` (i915/xe/radeonsi DRI drivers) and `pciutils` (for `lspci -nnk`) are
  installed explicitly; on QEMU only Mesa's software rasteriser was needed.
- A udev rule gives the `video` group access to `/dev/dri/*` as a fallback for
  the brief window before elogind registers an active seat.
- GRUB uses `gfxpayload=text` (and the kernel keeps `console=tty0`),
  matching the working CachyOS/systemd ISO — on real
  hardware a graphical handoff left the VT console blank. The custom initramfs
  hook `cosmalia_bootlog` records each boot stage in `BOOTLOG.TXT` on the USB's
  `ARCHISO_EFI` FAT partition; the launcher copies its log there as
  `SESSIONLOG.TXT` when Noctalia starts or DRM fails.

### Stall right after `squashfs: version 4.0`

That kernel line is printed when the squashfs module loads — immediately
before the initramfs mounts `/dev/loopN` on `/run/artix/sfs/airootfs` and
assembles the root overlay. To make the failure attributable, `cosmalia_bootlog`
now wraps both calls and prints `cosmalia: mount: start …` /
`cosmalia: mount: … returned …` and `cosmalia: overlay: …` to the console as
well as to `BOOTLOG.TXT`. A `cosmalia: root ready: …` marker from
`run_latehook()` means the root was mounted and `switch_root` is about to
execute dinit. `build.sh` also verifies `/sbin/init` → `dinit-init` and the
presence of the `cosmalia-session-dinit` user units in the live root.

If the console stops at a `mount: start dev=/dev/loopN …` marker, the stick is
stalling on a USB read. Boot the **copy squashfs to RAM** entry: it sets
`copytoram=y` so the image is read once into tmpfs and all later mounts come
from RAM. If it stops at the `overlay:` marker instead, the overlayfs options
in the hook are the place to look. Either way the log now says which one.

The menu has two entries (both boot dinit and cosmalia-session-dinit):

1. **Cosmalia Live (Artix dinit)** — normal boot: `copytoram=n`,
   `console=tty0` only. A registered serial console can hang bare-metal boots
   with no working COM1; the serial getty still runs for QEMU access.
2. **Cosmalia Live (safe, copy squashfs to RAM)** — `copytoram=y`,
   `loglevel=7`; use this if the normal entry stalls reading the USB stick
   (needs ~1.5 GB RAM).

DRM diagnostics (card list + drivers, GPU modules, `lspci -nnk`, filtered
`dmesg`, sessions) go to `/run/user/1000/cosmalia-session.log`.

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
cosmalia-session-dinit/iso/   # in the git checkout; also mirrored in /tmp
├── build.sh          # builds the local package + the ISO
├── test.sh           # headless QEMU verification (evidence in test-results/)
├── run.sh            # interactive QEMU with host internet
├── qemu-probe.py     # serial-console + HMP probe used by test.sh
├── out/              # generated ISOs (gitignored, chowned to the builder)
├── profile/
│   ├── profiledef.sh
│   ├── packages.x86_64
│   ├── pacman.conf                # template; @REPO_DIR@ substituted by build.sh
│   ├── mirrorlist-artix
│   ├── tools/mkarchiso            # vendored build tool (no Arch repo needed)
│   ├── grub/grub.cfg              # UEFI menu (mkarchiso substitutes tokens)

│   ├── syslinux/*.cfg             # BIOS menu
│   └── airootfs/                  # copied into the image before pacstrap
```
