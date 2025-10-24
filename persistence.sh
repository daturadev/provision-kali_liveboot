#!/usr/bin/env bash
set -euo pipefail

log(){ echo -e "[+] $*"; }
warn(){ echo -e "[!] $*"; }
die(){ echo -e "[✘] $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

# Identify the physical device for the live USB (read-only medium mount)
MEDIUM_SRC="$(findmnt -n -o SOURCE /lib/live/mount/medium 2>/dev/null || true)"
[[ -n "$MEDIUM_SRC" ]] || die "Could not find live USB mount source (are you on Kali Live?)."

# Strip partition number to get the disk (e.g., /dev/sdb1 -> /dev/sdb)
LIVE_DISK="/dev/$(lsblk -no PKNAME "$MEDIUM_SRC")"
[[ -b "$LIVE_DISK" ]] || die "Resolved live disk is not a block device: $LIVE_DISK"

log "Live USB disk detected: $LIVE_DISK"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL "$LIVE_DISK"

# Find existing persistence partition (if any)
PERSIST_DEV="$(blkid -L persistence || true)"

partprobe_sync(){ partprobe "$LIVE_DISK" || true; sleep 1; }

ensure_persistence_conf(){
  local mnt="$1"
  echo "/ union" > "$mnt/persistence.conf"
  sync
  log "Wrote $mnt/persistence.conf  ->  / union"
}

create_new_persistence(){
  log "Creating a new persistence partition on $LIVE_DISK using all free space…"

  # Find next free partition number
  NEXT_NUM=$(lsblk -lno NAME "$LIVE_DISK" | awk -v d="$(basename "$LIVE_DISK")" '$1 ~ d"[0-9]+"{n=$1} END{if(n){split(n,a,/[^0-9]/); print a[length(a)]+1}else print 1}')
  # Figure free space start
  END_LAST="$(parted -s "$LIVE_DISK" unit MiB print free | awk '/Free Space/ {start=$1; end=$2} END{print start}' | sed 's/MiB//')"
if [[ -z "$END_LAST" ]]; then  
  die "Could not determine free space start. Ensure there is free space available on the disk."
fi

  [[ -n "$END_LAST" ]] || die "Could not determine free space start."

  # Make the partition
  parted -s "$LIVE_DISK" mkpart primary ext4 "${END_LAST}MiB" 100%
  partprobe_sync

  NEW_PART="${LIVE_DISK}${NEXT_NUM}"
  [[ -b "$NEW_PART" ]] || die "New partition not found: $NEW_PART"

  # Format and label
  mkfs.ext4 -F -L persistence "$NEW_PART"
  mkdir -p /mnt/persist
  mount "$NEW_PART" /mnt/persist
  ensure_persistence_conf /mnt/persist
  umount /mnt/persist

  log "Created persistence partition: $NEW_PART (ext4, label=persistence)"
}

resize_ext4_partition(){
  local part="$1"
  log "Resizing $part to fill the disk…"
  # Get partition number
  PNUM="$(lsblk -no PARTNUM "$part")"
  [[ -n "$PNUM" ]] || die "Could not get partition number for $part"

  parted -s "$LIVE_DISK" resizepart "$PNUM" 100%
  partprobe_sync

  log "Running filesystem resize on $part…"
  e2fsck -f -p "$part" || true
  resize2fs "$part"
  log "Ext4 resize complete."
}

resize_luks_partition(){
  local part="$1" name="persistence_crypt"
  log "Resizing LUKS partition $part …"

  PNUM="$(lsblk -no PARTNUM "$part")"
  [[ -n "$PNUM" ]] || die "Could not get partition number for $part"

  parted -s "$LIVE_DISK" resizepart "$PNUM" 100%
  partprobe_sync

  # Open if not open
  if ! cryptsetup status "$name" >/dev/null 2>&1; then
    log "Opening LUKS container (you’ll be prompted for passphrase)…"
    cryptsetup open "$part" "$name"
  fi

  log "Resizing LUKS container and the ext4 inside…"
  cryptsetup resize "$name"
  e2fsck -f -p "/dev/mapper/$name" || true
  resize2fs "/dev/mapper/$name"

  # Ensure persistence.conf exists
  mkdir -p /mnt/persist
  mount "/dev/mapper/$name" /mnt/persist
  ensure_persistence_conf /mnt/persist
  umount /mnt/persist

  log "LUKS/FS resize complete."
}

# Branch: create or expand
if [[ -z "$PERSIST_DEV" ]]; then
  warn "No LABEL=persistence partition found on $LIVE_DISK."
  create_new_persistence
else
  # Ensure the found persistence device is on THIS disk
  PDEV_DISK="/dev/$(lsblk -no PKNAME "$PERSIST_DEV")"
  [[ "$PDEV_DISK" == "$LIVE_DISK" ]] || die "Found persistence on $PDEV_DISK, but live disk is $LIVE_DISK. Refusing to touch another disk."

  TYPE="$(blkid -o value -s TYPE "$PERSIST_DEV" || true)"
  if [[ "$TYPE" == "crypto_LUKS" ]]; then
    resize_luks_partition "$PERSIST_DEV"
  else
    resize_ext4_partition "$PERSIST_DEV"
    # Ensure persistence.conf
    mkdir -p /mnt/persist
    mount "$PERSIST_DEV" /mnt/persist
    ensure_persistence_conf /mnt/persist
    umount /mnt/persist
  fi
fi

echo
log "DONE. Reboot and choose a *Persistent* entry. Then run: df -h  (you should see big free space under /)."
