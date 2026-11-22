#!/usr/bin/env bash
# shellcheck disable=SC2034

# Cosmalia live ISO — Artix Linux with dinit, minimal COSMIC/Noctalia desktop.
iso_name="cosmalia-artix-dinit"
iso_label="COSMALIA_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Cosmalia <https://github.com/grigio/cosmalia-session-dinit>"
iso_application="Cosmalia Live (Artix Linux / dinit)"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="cosmalia"
bootmodes=('bios.syslinux' 'uefi.grub')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15' '-b' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/root"]="0:0:700"
  # /home/liveuser is created by mkarchiso from passwd + skel.
  ["/etc/sudoers.d/99-liveuser"]="0:0:440"
)
