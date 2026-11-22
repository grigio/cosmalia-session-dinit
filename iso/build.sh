#!/usr/bin/env bash
# Build a minimal Artix Linux (dinit) live ISO that boots straight into
# Cosmalia via greetd + tuigreet.
#
# Run as the normal user (makepkg refuses to run as root). Only mkarchiso is
# invoked through sudo. Nothing on the host is installed or overwritten:
# packages are built into iso/local-repo and the ISO appears in iso/out/.
set -euo pipefail

ISO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# This project lives outside the source repo on purpose (no uncommitted files
# spread through the checkout). Point SESSION_SRC_DIR at the repo; override for
# CI or a different checkout.
SRC_DIR="${SESSION_SRC_DIR:-/home/g/Code/cosmalia-session-dinit}"
[[ -f "$SRC_DIR/PKGBUILD" ]] || {
    echo "SESSION_SRC_DIR does not look like the cosmalia-session-dinit repo: $SRC_DIR" >&2
    exit 1
}
SOURCE_PROFILE="$ISO_DIR/profile"
REPO_DIR="${ISO_REPO_DIR:-$ISO_DIR/local-repo}"
OUT_DIR="${ISO_OUT_DIR:-$ISO_DIR/out}"
WORK_DIR="${ISO_WORK_DIR:-/tmp/opencode/cosmalia-artix-dinit-iso-work}"
# Work on a copy: generated pacman.conf / package list never touch the source.
PROFILE="$WORK_DIR/profile"

# Guard: all generated files (build work dir, local repo, ISO) must live
# outside the source checkout. Never leave uncommitted/root-owned files in it.
for d in "$REPO_DIR" "$OUT_DIR" "$WORK_DIR"; do
    case "$(realpath -m -- "$d")" in
        "$SRC_DIR"|"$SRC_DIR"/*)
            echo "Refusing to write generated files inside the source repo: $d" >&2
            exit 1
            ;;
    esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
SUDO=(); (( EUID == 0 )) || SUDO=(sudo)

for tool in makepkg repo-add mkarchiso curl; do
    command -v "$tool" >/dev/null || { echo "$tool not found (see README.md)" >&2; exit 1; }
done

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
# 1b. cosmic-comp-traffic from the pinned upstream release. Its .PKGINFO
#     declares `systemd-libs`, which Artix does not ship. The compositor binary
#     has no direct libsystemd dependency (only libseat, which Artix links
#     against libelogind), so rewrite that single dependency before adding the
#     package to the local repository. Set COSMIC_COMP_PKG to use a local copy.
# ---------------------------------------------------------------------------
COMP_ASSET="${COSMIC_COMP_PKG:-}"
COMP_DIR="$ISO_DIR/packages"
mkdir -p "$COMP_DIR"
if [[ -n "$COMP_ASSET" ]]; then
    [[ -f "$COMP_ASSET" ]] || { echo "COSMIC_COMP_PKG does not exist: $COMP_ASSET" >&2; exit 1; }
else
    COMP_ASSET="$COMP_DIR/cosmic-comp-traffic-1.12.0.rc1-32-x86_64.pkg.tar.zst"
    if [[ ! -f "$COMP_ASSET" ]]; then
        log "Downloading cosmic-comp-traffic (${COSMIC_COMP_TAG:-epoch-1.12.0-rc.1})"
        curl -fsSL --max-time 300 -o "$COMP_ASSET" \
            "https://github.com/grigio/cosmic-comp-traffic/releases/download/${COSMIC_COMP_TAG:-epoch-1.12.0-rc.1}/$(basename "$COMP_ASSET")"
    fi
fi

log "Repacking $(basename "$COMP_ASSET") with libelogind instead of systemd-libs"
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
# 2. Pick a browser. brave-origin is not in the configured repos; Arch [extra]
#    (enabled in our pacman.conf) has chromium, which is the documented
#    fallback. A third choice, ungoogled-chromium, is kept for repo setups
#    where Arch mirrors are unavailable.
# ---------------------------------------------------------------------------
probe_conf="$WORK_DIR/browser-probe-pacman.conf"
probe_db="$WORK_DIR/browser-probe-db"
sed "s|@REPO_DIR@|$REPO_DIR|g" "$SOURCE_PROFILE/pacman.conf" >"$probe_conf"
mkdir -p "$probe_db"

repo_has() {
    pacman -b "$probe_db" --config "$probe_conf" -Si "$1" >/dev/null 2>&1
}

log "Probing repositories for a browser package"
"${SUDO[@]}" pacman -b "$probe_db" --config "$probe_conf" -Sy --noconfirm >/dev/null 2>&1 || true

BROWSER_PKG=""
BROWSER_NAME=""
if [[ -n "${COSMALIA_BROWSER:-}" ]]; then
    BROWSER_PKG="$COSMALIA_BROWSER"
    case "$BROWSER_PKG" in
        brave*) BROWSER_NAME="brave-origin" ;;
        *ungoogled*) BROWSER_NAME="ungoogled-chromium" ;;
        *) BROWSER_NAME="Chromium" ;;
    esac
    log "Browser forced by COSMALIA_BROWSER: $BROWSER_PKG"
else
    for candidate in brave-origin-bin brave-origin chromium ungoogled-chromium; do
        if repo_has "$candidate"; then
            BROWSER_PKG="$candidate"
            case "$candidate" in
                brave*) BROWSER_NAME="brave-origin" ;;
                *ungoogled*) BROWSER_NAME="ungoogled-chromium" ;;
                *) BROWSER_NAME="Chromium" ;;
            esac
            break
        fi
    done
fi

if [[ -z "$BROWSER_PKG" ]]; then
    echo "No browser package found. Install one of: chromium, ungoogled-chromium," >&2
    echo "brave-origin-bin. Set COSMALIA_BROWSER to override the probe." >&2
    exit 1
fi
log "Using browser: $BROWSER_PKG (dock entry: $BROWSER_NAME)"

# ---------------------------------------------------------------------------
# 3. Generate the build pacman.conf, local repository and package list.
# ---------------------------------------------------------------------------
sed "s|@REPO_DIR@|$REPO_DIR|g" "$SOURCE_PROFILE/pacman.conf" >"$PROFILE/pacman.conf"

# The live image uses Include paths, so ship the mirrorlists it references.
# The directory can be absent in a fresh checkout (git does not track empties).
mkdir -p "$PROFILE/airootfs/etc/pacman.d"
cp -f "$SOURCE_PROFILE/mirrorlist-artix" "$SOURCE_PROFILE/mirrorlist-arch" \
    "$PROFILE/airootfs/etc/pacman.d/"

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
log "Running mkarchiso (work: $WORK_DIR, output: $OUT_DIR)"
"${SUDO[@]}" env "PATH=$PATH" mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE"

echo
log "Finished. ISO files:"
ls -lh "$OUT_DIR"/*.iso
