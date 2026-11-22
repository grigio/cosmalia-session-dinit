#!/usr/bin/env bash
# Runs inside the ISO chroot after all packages are installed.
set -euo pipefail

# ---------------------------------------------------------------------------
# D-Bus stubs: a live session must not show a keyring password prompt, and the
# cosmic portal backend is explicitly unused (Screenshot/ScreenCast go to wlr).
# Keep the packages installed so dependencies stay satisfied, but make their
# D-Bus activation targets no-ops.
# ---------------------------------------------------------------------------
cat >/usr/share/dbus-1/services/org.freedesktop.secrets.service <<'EOF'
[D-BUS Service]
Name=org.freedesktop.secrets
Exec=/usr/bin/true
EOF
chmod 0644 /usr/share/dbus-1/services/org.freedesktop.secrets.service

cat >/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.cosmic.service <<'EOF'
[D-BUS Service]
Name=org.freedesktop.impl.portal.desktop.cosmic
Exec=/usr/bin/true
EOF
chmod 0644 /usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.cosmic.service

# ---------------------------------------------------------------------------
# pacman works in the live system (signed packages from Artix + Arch extra).
# ---------------------------------------------------------------------------
pacman-key --init
pacman-key --populate artix archlinux

# A build host with a newer libalpm writes a `%INSTALLED_DB%` key into the
# local package database (e.g. for the two [cosmalia] packages). The Artix
# pacman in the image does not know that key and warns on every invocation
# ("unknown key %INSTALLED_DB% in local database"). Drop it from the records.
for desc in /var/lib/pacman/local/*/desc; do
    [[ -f "$desc" ]] || continue
    sed -i '/^%INSTALLED_DB%$/,+1d' "$desc"
done

# greetd is a daemon: PAM_TTY is not set, so pam_securetty refuses autologin
# and silently falls back to the greeter. Arch's greetd PAM stack ships it.
if [[ -f /etc/pam.d/greetd ]]; then
    sed -i '/pam_securetty\.so/d' /etc/pam.d/greetd
fi

# ---------------------------------------------------------------------------
# dinit wiring. Artix packages install the service definitions but do not
# necessarily enable them; under dinit "enabled" means a symlink in boot.d.
# ---------------------------------------------------------------------------
install -d -m 0755 /etc/dinit.d/boot.d

# System bus (elogind, greetd and Noctalia all need it).
ln -sfn ../dbus /etc/dinit.d/boot.d/dbus
# DHCP/DNS in the live session (Arch's systemd preset does this by default;
# under dinit the service must be enabled explicitly).
ln -sfn ../NetworkManager /etc/dinit.d/boot.d/NetworkManager
# greetd itself: depends-on login.target, takes vt1 and autologins liveuser.
ln -sfn ../greetd /etc/dinit.d/boot.d/greetd

# dinit-rc starts getty on tty1-6 by default; tty1 belongs to greetd.
rm -f /usr/lib/dinit.d/boot.d/agetty

# Serial console getty for the QEMU test harness (and for debugging on real
# hardware with console=ttyS0). /usr/lib/dinit.d/boot.d/agetty is gone, so
# create a standalone service instead.
# NOTE: no '@' in the name — dinit treats it as a template/instance separator
# and will not resolve "serial-getty@ttyS0" as a plain service name.
cat >/etc/dinit.d/serial-getty-ttyS0 <<'EOF'
type        = process
command     = /usr/lib/dinit/agetty-default ttyS0 115200 linux
restart     = true
depends-on  = login.target
termsignal  = HUP
smooth-recovery = true
EOF
chmod 0644 /etc/dinit.d/serial-getty-ttyS0
ln -sfn ../serial-getty-ttyS0 /etc/dinit.d/boot.d/serial-getty-ttyS0

# Noctalia's idle/lock integration must not suspend a live USB stick.
install -d -m 0755 /etc/elogind/logind.conf.d
cat >/etc/elogind/logind.conf.d/99-cosmalia.conf <<'EOF'
[Login]
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
EOF
chmod 0644 /etc/elogind/logind.conf.d/99-cosmalia.conf
