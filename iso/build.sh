#!/usr/bin/env bash
# Build a minimal Artix Linux (dinit) live ISO that boots straight into
# Cosmalia via greetd + tuigreet.
#
# Run as the normal user (makepkg refuses to run as root). Only mkarchiso is
# invoked through sudo. Nothing on the host is installed or overwritten:
# packages are built into iso/local-repo and the ISO appears in iso/out/.
set -euo pipefail

ISO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Keep the generated packages and the mkarchiso work dir outside the source
# repo, but put the finished ISO in the project's own (gitignored) iso/out/.
# Point SESSION_SRC_DIR at the repo; override for CI or a different checkout.
SRC_DIR="${SESSION_SRC_DIR:-$HOME/Code/cosmalia-session-dinit}"
[[ -f "$SRC_DIR/PKGBUILD" ]] || {
    echo "SESSION_SRC_DIR does not look like the cosmalia-session-dinit repo: $SRC_DIR" >&2
    exit 1
}
SOURCE_PROFILE="$ISO_DIR/profile"
REPO_DIR="${ISO_REPO_DIR:-/tmp/opencode/cosmalia-session-dinit-iso/local-repo}"
OUT_DIR="${ISO_OUT_DIR:-$SRC_DIR/iso/out}"
WORK_DIR="${ISO_WORK_DIR:-/tmp/opencode/cosmalia-artix-dinit-iso-work}"
# Work on a copy: generated pacman.conf / package list never touch the source.
PROFILE="$WORK_DIR/profile"

# Guard: packages and mkarchiso scratch must stay outside the source checkout
# (no root-owned build debris in git). The finished ISO is the one exception:
# it belongs in "$SRC_DIR/iso/out", which is gitignored.
SRC_REAL="$(realpath -m -- "$SRC_DIR")"
ISO_OUT_REAL="$SRC_REAL/iso/out"
OUT_REAL="$(realpath -m -- "$OUT_DIR")"
for d in "$REPO_DIR" "$WORK_DIR"; do
    case "$(realpath -m -- "$d")" in
        "$SRC_REAL"|"$SRC_REAL"/*)
            echo "Refusing to write build scratch inside the source repo: $d" >&2
            exit 1
            ;;
    esac
done
case "$OUT_REAL" in
    "$ISO_OUT_REAL"|"$ISO_OUT_REAL"/*) ;;
    "$SRC_REAL"|"$SRC_REAL"/*)
        echo "Refusing to write the ISO inside the source repo outside $ISO_OUT_REAL: $OUT_DIR" >&2
        exit 1
        ;;
esac

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
SUDO=(); (( EUID == 0 )) || SUDO=(sudo)

for tool in makepkg repo-add curl; do
    command -v "$tool" >/dev/null || { echo "$tool not found (see README.md)" >&2; exit 1; }
done
# mkarchiso is vendored in iso/tools so the build needs no Arch repository.
# The strap tool is basestrap on Artix (artools-base) or pacstrap elsewhere.
[[ -x "$ISO_DIR/tools/mkarchiso" ]] || {
    echo "vendored mkarchiso not found: $ISO_DIR/tools/mkarchiso" >&2
    exit 1
}
command -v basestrap >/dev/null 2>&1 || command -v pacstrap >/dev/null 2>&1 || {
    echo "neither basestrap nor pacstrap found (install artools-base on Artix)" >&2
    exit 1
}

mkdir -p "$REPO_DIR" "$OUT_DIR"
# mkarchiso uses _run_once markers in the work dir; reuse would silently skip
# the changed profile files. This directory is build-only scratch space.
"${SUDO[@]}" rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cp -a "$SOURCE_PROFILE" "$PROFILE"
rm -f "$OUT_DIR"/*.iso

# ---------------------------------------------------------------------------
# 1. Build cosmalia-session-dinit from this source tree (pure file-copy pkg).
# ---------------------------------------------------------------------------
log "Building cosmalia-session-dinit package from $SRC_DIR"
(
    cd "$SRC_DIR"
    # Runtime deps are pulled into the ISO by pacstrap; the build host does not
    # need cosmic-comp/noctalia installed (CI builds in a bare Artix container).
    PKGDEST="$REPO_DIR" makepkg --noconfirm --force --nodeps
)

# ---------------------------------------------------------------------------
# 1b. cosmic-comp-traffic from the pinned upstream release (epoch-1.12.0).
#     Older builds declared `systemd-libs`, which Artix does not ship; the
#     rewrite below is a no-op for the pinned release but is kept as a safety
#     net. The compositor binary has no direct libsystemd dependency (only
#     libseat, which Artix links against libelogind). Set COSMIC_COMP_PKG to
#     use a local copy.
# ---------------------------------------------------------------------------
COMP_TAG="${COSMIC_COMP_TAG:-epoch-1.12.0}"
COMP_ASSET="${COSMIC_COMP_PKG:-}"
COMP_DIR="$ISO_DIR/packages"
mkdir -p "$COMP_DIR"
if [[ -n "$COMP_ASSET" ]]; then
    [[ -f "$COMP_ASSET" ]] || { echo "COSMIC_COMP_PKG does not exist: $COMP_ASSET" >&2; exit 1; }
else
    COMP_ASSET="$COMP_DIR/cosmic-comp-traffic-1.12.0-39-x86_64.pkg.tar.zst"
    if [[ ! -f "$COMP_ASSET" ]]; then
        log "Downloading cosmic-comp-traffic ($COMP_TAG)"
        curl -fsSL --max-time 300 -o "$COMP_ASSET" \
            "https://github.com/grigio/cosmic-comp-traffic/releases/download/$COMP_TAG/$(basename "$COMP_ASSET")"
    fi
fi

log "Repacking $(basename "$COMP_ASSET") for the local [cosmalia] repository"
comp_extract="$WORK_DIR/cosmic-comp-traffic"
mkdir -p "$comp_extract"
tar -xf "$COMP_ASSET" -C "$comp_extract"
sed -i 's|^depend = systemd-libs$|depend = libelogind|' "$comp_extract/.PKGINFO"
comp_pkg="$REPO_DIR/$(basename "$COMP_ASSET")"
(
    cd "$comp_extract"
    files=(.PKGINFO)
    while IFS= read -r -d '' f; do
        [[ $f == .PKGINFO ]] || files+=("$f")
    done < <(find . -mindepth 1 -maxdepth 1 -printf '%P\0')
    tar --zstd -cf "$comp_pkg" "${files[@]}"
)

# Create the local repository early so the browser probe below can sync all
# configured databases (including [cosmalia]) without errors.
rm -f "$REPO_DIR/cosmalia.db.tar.gz" "$REPO_DIR/cosmalia.files.tar.gz"
repo-add "$REPO_DIR/cosmalia.db.tar.gz" "$REPO_DIR"/*.pkg.tar.zst >/dev/null

# ---------------------------------------------------------------------------
# 2. Pick a browser. Only Artix repos are configured: galaxy ships
#    ungoogled-chromium and firefox. Noctalia dock pins need the exact
#    desktop-entry stem, not the human-readable Name.
# ---------------------------------------------------------------------------
probe_conf="$WORK_DIR/browser-probe-pacman.conf"
probe_db="$WORK_DIR/browser-probe-db"
sed "s|@REPO_DIR@|$REPO_DIR|g" "$SOURCE_PROFILE/pacman.conf" >"$probe_conf"
mkdir -p "$probe_db"

repo_has() {
    pacman -b "$probe_db" --config "$probe_conf" -Si "$1" >/dev/null 2>&1
}

log "Probing Artix repositories for a browser package"
"${SUDO[@]}" pacman -b "$probe_db" --config "$probe_conf" -Sy --noconfirm >/dev/null 2>&1 || true

BROWSER_PKG=""
BROWSER_NAME=""
if [[ -n "${COSMALIA_BROWSER:-}" ]]; then
    BROWSER_PKG="$COSMALIA_BROWSER"
    BROWSER_NAME="$BROWSER_PKG"
    [[ "$BROWSER_PKG" == ungoogled-chromium ]] && BROWSER_NAME="chromium"
    log "Browser forced by COSMALIA_BROWSER: $BROWSER_PKG (dock: $BROWSER_NAME)"
else
    for candidate in ungoogled-chromium firefox; do
        if repo_has "$candidate"; then
            BROWSER_PKG="$candidate"
            # Artix ungoogled-chromium ships chromium.desktop (Exec=chromium),
            # not ungoogled-chromium.desktop. Noctalia pins the desktop stem.
            BROWSER_NAME="$candidate"
            [[ "$candidate" == ungoogled-chromium ]] && BROWSER_NAME="chromium"
            break
        fi
    done
fi

if [[ -z "$BROWSER_PKG" ]]; then
    echo "No browser package found in the Artix repositories (tried" >&2
    echo "ungoogled-chromium, firefox). Set COSMALIA_BROWSER to override." >&2
    exit 1
fi
log "Using browser: $BROWSER_PKG (dock entry: $BROWSER_NAME)"

# ---------------------------------------------------------------------------
# 3. Generate the build pacman.conf, local repository and package list.
# ---------------------------------------------------------------------------
sed "s|@REPO_DIR@|$REPO_DIR|g" "$SOURCE_PROFILE/pacman.conf" >"$PROFILE/pacman.conf"

# Use a build-only package cache: mkarchiso passes -c to pacstrap/basestrap,
# which would otherwise reuse the host's cache. A cache shared with another
# distro can contain stale packages that fail the database checksum.
mkdir -p "$WORK_DIR/pkg-cache"
sed -i "/^\[options\]/a CacheDir = $WORK_DIR/pkg-cache" "$PROFILE/pacman.conf"

# The live image uses Include paths, so ship the mirrorlists it references.
# The directory can be absent in a fresh checkout (git does not track empties).
mkdir -p "$PROFILE/airootfs/etc/pacman.d"
cp -f "$SOURCE_PROFILE/mirrorlist-artix" "$PROFILE/airootfs/etc/pacman.d/"

# Dock pin is the chosen browser's desktop name, not its pacman package name.
sed -i "s|@BROWSER@|$BROWSER_NAME|g" \
    "$PROFILE/airootfs/etc/skel/.local/state/noctalia/settings.toml"

# The pinned traffic build provides/replaces cosmic-comp, so drop the repo
# package and install the local one instead.
sed -i '/^cosmic-comp$/d' "$PROFILE/packages.x86_64"
printf '\n# compositor: pinned cosmic-comp-traffic release (local repo)\ncosmic-comp-traffic\n' \
    >>"$PROFILE/packages.x86_64"

printf '\n# browser chosen by build.sh: %s\n%s\n' "$BROWSER_PKG" "$BROWSER_PKG" \
    >>"$PROFILE/packages.x86_64"

log "Local repository ready:"
find "$REPO_DIR" -maxdepth 1 -name '*.pkg.tar.zst' -printf '    %f\n' | sort

# ---------------------------------------------------------------------------
# 4. Build the ISO.
# ---------------------------------------------------------------------------
log "Running mkarchiso (UEFI: GRUB; work: $WORK_DIR, output: $OUT_DIR)"
"${SUDO[@]}" env "PATH=$ISO_DIR/tools:$PATH" "$ISO_DIR/tools/mkarchiso" -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE"

# Fail loudly if our initramfs hook is only copied (add_file) instead of
# registered (add_runscript): in that case run_hook() never runs and both the
# boot log and the overlay-mount override are silently absent.
initrd="$(find "$WORK_DIR/iso" -name 'initramfs-linux.img' -print -quit)"
check_dir="$(mktemp -d)"
if [[ -z "$initrd" ]] || ! ( cd "$check_dir" && lsinitcpio -x "$initrd" >/dev/null 2>&1 ); then
    echo "Could not inspect the generated initramfs: $initrd" >&2
    exit 1
fi
for hook in artix artix_loop_mnt cosmalia_bootlog; do
    grep -q "$hook" "$check_dir/config" || {
        echo "initramfs hook $hook is not registered (check its install script)" >&2
        exit 1
    }
done
# The boot-log hook is also the progress beacon for the reported
# "stuck at squashfs: version 4.0" stall. Guard against an accidentally stale
# or trimmed copy being shipped in the initramfs.
grep -q 'mount: start dev=' "$check_dir/hooks/cosmalia_bootlog" || {
    echo "generated initramfs lacks the cosmalia boot-stage markers" >&2
    exit 1
}
rm -rf "$check_dir"
log "Verified Artix live hooks and cosmalia_bootlog are registered in the initramfs"

# ---------------------------------------------------------------------------
# 4b. Verify the handoff after switch_root: /sbin/init must be dinit, and the
#     launcher + user dinit units from cosmalia-session-dinit must be present.
#     A broken /sbin/init is indistinguishable from an initramfs hang unless
#     it is checked here.
# ---------------------------------------------------------------------------
live_root="$WORK_DIR/x86_64/airootfs"
for target in sbin/init usr/bin/init; do
    resolved="$(readlink "$live_root/$target" 2>/dev/null || true)"
    [[ "$resolved" == *dinit-init ]] || {
        echo "$target must point at dinit-init, got '${resolved:-<not a symlink>}'" >&2
        exit 1
    }
done
for required in usr/bin/cosmalia-session \
                etc/dinit.d/user/cosmalia-session.target \
                etc/dinit.d/user/noctalia \
                etc/dinit.d/user/cosmic-settings-daemon; do
    [[ -e "$live_root/$required" ]] || {
        echo "missing $required in the live root (cosmalia-session-dinit not installed?)" >&2
        exit 1
    }
done
log "Verified /sbin/init -> dinit and cosmalia-session-dinit user units in the live root"

# mkarchiso runs as root, so the ISO would otherwise be root-owned in the
# checkout. Hand it back to the invoking user (gitignored, see iso/.gitignore).
if (( EUID != 0 )) && compgen -G "$OUT_DIR/*.iso" >/dev/null; then
    "${SUDO[@]}" chown "$(id -u):$(id -g)" "$OUT_DIR"/*.iso
fi

echo
log "Finished. ISO files (in the project, gitignored):"
ls -lh "$OUT_DIR"/*.iso
