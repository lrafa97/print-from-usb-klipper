#!/usr/bin/env bash
# Mounts/unmounts a USB stick (read-only) at a fixed mount point.
# Called by the systemd service usb-gcode@<device>.service.
#   usb-gcode.sh mount   /dev/sda1
#   usb-gcode.sh umount  /dev/sda1
set -euo pipefail

# shellcheck source=/dev/null
source /etc/usb-gcode.conf   # MOUNTPOINT, MOUNT_UID, MOUNT_GID

action="${1:?missing action}"
dev="${2:?missing device}"

log() { logger -t usb-gcode -- "$*"; }

# Serialize: two sticks inserted at once never step on each other
exec 9>/run/usb-gcode.lock
flock 9

case "$action" in
  mount)
    [[ -b "$dev" ]] || { log "$dev no longer exists"; exit 0; }

    # Never touch devices that are already mounted (e.g. booting from a USB SSD)
    if findmnt -rn -S "$dev" >/dev/null; then
      log "$dev is already mounted, ignoring"; exit 0
    fi
    if mountpoint -q "$MOUNTPOINT"; then
      log "$MOUNTPOINT is busy, ignoring $dev"; exit 0
    fi

    fstype="$(blkid -p -o value -s TYPE "$dev" 2>/dev/null || true)"
    base="ro,nosuid,nodev,noexec"
    owner="uid=${MOUNT_UID},gid=${MOUNT_GID}"
    case "$fstype" in
      vfat)            args=(-t vfat  -o "${base},${owner},umask=022,iocharset=utf8,shortname=mixed") ;;
      exfat)           args=(-t exfat -o "${base},${owner},umask=022") ;;
      ntfs)            args=(-t ntfs3 -o "${base},${owner},umask=022") ;;
      ext2|ext3|ext4)  args=(-t ext4  -o "${base},noload") ;;
      *) log "$dev: unsupported filesystem '${fstype:-unknown}'"; exit 0 ;;
    esac

    mkdir -p "$MOUNTPOINT"
    if mount "${args[@]}" "$dev" "$MOUNTPOINT"; then
      log "$dev ($fstype) mounted at $MOUNTPOINT"
    else
      log "failed to mount $dev ($fstype)"; exit 1
    fi
    ;;

  umount)
    # Only unmount if what is mounted is really this device
    src="$(findmnt -rn -M "$MOUNTPOINT" -o SOURCE 2>/dev/null || true)"
    if [[ "$src" == "$dev" ]]; then
      umount -l "$MOUNTPOINT" && log "$dev unmounted"
    fi
    ;;

  *) echo "unknown action: $action" >&2; exit 2 ;;
esac
