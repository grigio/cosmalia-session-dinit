#!/usr/bin/env bash
# shellcheck disable=SC2034

# Cosmalia live ISO — Artix Linux with dinit, minimal COSMIC/Noctalia desktop.
iso_name="cosmalia-artix-dinit"
iso_label="COSMALIA_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Cosmalia <https://github.com/grigio/cosmalia-session-dinit>"
iso_application="Cosmalia Live (Artix Linux / dinit)"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="cosmalia"
# Artix's official live ISOs use GRUB (UEFI) + syslinux (BIOS).
bootmodes=('bios.syslinux' 'uefi.grub')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
# zstd 15 made a ~1.4 GB image but was slow to write/read. Level 3 is much
# faster to compress and decompress; the image grows but still fits a 2 GB+
# USB stick, and boot from real hardware is noticeably quicker.
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '3' '-b' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/root"]="0:0:700"
  # /home/liveuser is created by mkarchiso from passwd + skel.
  ["/etc/sudoers.d/99-liveuser"]="0:0:440"
  # Cosmalia installer tooling.
  ["/usr/local/bin/cosmalia-installer"]="0:0:755"
  ["/usr/local/bin/cosmalia-postinstall"]="0:0:755"
  ["/usr/local/bin/cosmalia-limine-install"]="0:0:755"
)
