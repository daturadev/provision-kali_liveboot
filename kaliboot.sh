!/usr/bin/env bash
set -euo pipefail

log(){ printf "\n[+] %s\n" "$*"; }
warn(){ printf "\n[!] %s\n" "$*"; }
die(){ printf "\n[✘] %s\n" "$*"; exit 1; }

# 0) Sanity checks
[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
command -v systemctl >/dev/null || die "systemctl not found (unexpected on Kali)."

# 1) Quick fix alias and helper
log "Installing quick GUI recovery alias: 'fixcursor' -> restart LightDM"
cat >/usr/local/sbin/restart-gui.sh <<'EOF'
#!/usr/bin/env bash
set -e
systemctl restart lightdm
EOF
chmod +x /usr/local/sbin/restart-gui.sh

# Add alias for all future interactive shells
if ! grep -q 'alias fixcursor=' /etc/skel/.bashrc 2>/dev/null; then
  echo "alias fixcursor='sudo /usr/local/sbin/restart-gui.sh'" | tee -a /etc/skel/.bashrc >/dev/null
fi
# Current user envs
for HOME_DIR in /home/* /root; do
  [[ -d "$HOME_DIR" ]] || continue
  if ! grep -q 'alias fixcursor=' "$HOME_DIR/.bashrc" 2>/dev/null; then
    echo "alias fixcursor='sudo /usr/local/sbin/restart-gui.sh'" >> "$HOME_DIR/.bashrc" || true
  fi
done

# 2) Enable Magic SysRq persistently (soft reboot during partial hangs)
log "Enabling Magic SysRq persistently"
mkdir -p /etc/sysctl.d
echo 'kernel.sysrq=1' >/etc/sysctl.d/99-sysrq.conf
sysctl --system >/dev/null || true

# 3) Prefer Xorg and harden LightDM a bit (Wayland can hang on some GPUs)
if [ -d /etc/lightdm ]; then
  log "Configuring LightDM to start X with -core (avoids some freezes)"
  if ! grep -q '^xserver-command=' /etc/lightdm/lightdm.conf 2>/dev/null; then
    printf "\n[Seat:*]\nxserver-command=X -core\n" >> /etc/lightdm/lightdm.conf
  fi
fi

# 4) Try to add 'nomodeset' to GRUB on the live USB (optional best effort)
add_nomodeset() {
  local medium mnt cfg
  medium="$(findmnt -n -o SOURCE /lib/live/mount/medium 2>/dev/null || true)"
  [[ -n "$medium" ]] || return 0
  mnt=/mnt/liveusb-boot
  mkdir -p "$mnt"
  # Mount the partition read-write if possible
  if ! mount | grep -q "$mnt"; then
    mount "$medium" "$mnt" || return 0
  fi

  # Kali live uses GRUB; edit the USB’s grub.cfg (not the in-RAM one)
  cfg=""
  for c in "$mnt"/boot/grub/grub.cfg "$mnt"/grub/grub.cfg; do
    [[ -f "$c" ]] && cfg="$c" && break
  done
  [[ -n "$cfg" ]] || { umount "$mnt" || true; return 0; }

  log "Attempting to add 'nomodeset' to $cfg (backup first)"
  cp -a "$cfg" "$cfg.bak.$(date +%s)"
  # Add nomodeset to linux lines that boot the live system (idempotent)
  sed -i '/^[[:space:]]*linux /{
    /nomodeset/! s/$/ nomodeset/
  }' "$cfg"

  sync
  umount "$mnt" || true
}
add_nomodeset || warn "Could not modify GRUB on the USB (non-fatal)."

# 5) Persistence activation (existing persistence only)
#    Works for LABEL=persistence (unencrypted) or LUKS with that label.
log "Looking for an existing persistence partition…"
PDEV_RAW="$(blkid -L persistence || true)"

open_and_mount_luks() {
  local dev="$1" name mountpoint
  name="persistence_crypt"
  mountpoint="/mnt/persistence"
  mkdir -p "$mountpoint"

  if ! cryptsetup status "$name" >/dev/null 2>&1; then
    log "Opening LUKS container $dev (you will be prompted for the passphrase)…"
    cryptsetup open "$dev" "$name"
  fi

  if ! mount | grep -q "$mountpoint"; then
    mount "/dev/mapper/$name" "$mountpoint"
  fi

  echo "/ union" > "$mountpoint/persistence.conf"
  sync
  log "persistence.conf written. Persistence will be active on next boot."
}

mount_plain_persistence() {
  local dev="$1" mountpoint="/mnt/persistence"
  mkdir -p "$mountpoint"
  mount "$dev" "$mountpoint"
  echo "/ union" > "$mountpoint/persistence.conf"
  sync
  umount "$mountpoint" || true
  log "persistence.conf written on $dev. Persistence will be active on next boot."
}

if [[ -n "$PDEV_RAW" ]]; then
  # Determine if it is LUKS or plain
  TYPE="$(blkid -o value -s TYPE "$PDEV_RAW" || true)"
  if [[ "$TYPE" == "crypto_LUKS" ]]; then
    open_and_mount_luks "$PDEV_RAW"
  else
    mount_plain_persistence "$PDEV_RAW"
  fi
else
  # Maybe the persistence is inside a LUKS container without label; try to guess
  CANDIDATE="$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | head -n1 || true)"
  if [[ -n "$CANDIDATE" ]]; then
    warn "Found a LUKS device ($CANDIDATE) but no label. Trying to open it…"
    open_and_mount_luks "$CANDIDATE"
  else
    warn "No persistence partition found. (LABEL=persistence not present)"
    warn "If you already created one, ensure it’s labeled 'persistence'."
  fi
fi

# 6) Final message & quick tips
cat <<'EOT'

[✓] Setup complete.

Shortcuts you now have:
  - Type:  fixcursor         # restarts the GUI (LightDM)
  - Soft reboot during partial freeze: hold Alt + SysRq, then press R E I S U B (1s apart)

Persistence:
  - If a persistence partition (plain or LUKS) was found, /persistence.conf is set to:  / union
  - Reboot to make persistence active (choose the *persistent* entry in the boot menu).

GPU freeze prevention:
  - 'nomodeset' was added to the live USB’s GRUB entries (if the device could be mounted).
    If you still freeze, at the GRUB menu you can also press 'e' and append 'nomodeset' manually.

EOT
