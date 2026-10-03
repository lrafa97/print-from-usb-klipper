#!/usr/bin/env bash
# Installer for print-from-usb-klipper. Idempotent: safe to run several times.
#   ./install.sh [--no-restart]
# Optional environment variables: PRINTER_DATA, MOONRAKER_DIR, TARGET_USER
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Elevates itself (the clone keeps the right owner, the install runs as root)
if [[ $EUID -ne 0 ]]; then exec sudo -E "$0" "$@"; fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || {
  echo "Could not determine the Klipper user. Use TARGET_USER=<name>." >&2; exit 1; }
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
UID_N="$(id -u "$TARGET_USER")"
GID_N="$(id -g "$TARGET_USER")"

PRINTER_DATA="${PRINTER_DATA:-$HOME_DIR/printer_data}"
MOONRAKER_DIR="${MOONRAKER_DIR:-$HOME_DIR/moonraker}"
MOUNTPOINT="$PRINTER_DATA/gcodes/USB"
LIB=/usr/local/lib/usb-gcode
BEGIN="# >>> usb-gcode >>>"
END="# <<< usb-gcode <<<"

RESTART=1; [[ "${1:-}" == "--no-restart" ]] && RESTART=0
FIRST=1;   [[ -f /etc/usb-gcode.conf ]] && FIRST=0

for cmd in findmnt flock blkid logger mount systemctl udevadm; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done
for p in "$PRINTER_DATA/config/printer.cfg" "$PRINTER_DATA/config/moonraker.conf" \
         "$MOONRAKER_DIR/moonraker/components"; do
  [[ -e "$p" ]] || { echo "Not found: $p" >&2
                     echo "(override with PRINTER_DATA=... or MOONRAKER_DIR=...)" >&2; exit 1; }
done

# 'usbmount' (found on some printer images) mounts sticks inside udev's private
# mount namespace, which makes our own mount fail with "mount point busy".
if dpkg -s usbmount >/dev/null 2>&1; then
  echo "==> Removing 'usbmount' (conflicts with this tool)"
  apt-get purge -y usbmount
  echo "    Reboot once after the install so no stale mount is left behind."
fi

echo "==> System files"
# Copied to a root-owned location: root never executes anything the user can edit
install -d "$LIB"
install -m 755 "$SRC/src/usb-gcode.sh"  "$LIB/usb-gcode.sh"
install -m 644 "$SRC/src/usb_import.py" "$LIB/usb_import.py"

cat > /etc/usb-gcode.conf <<EOF
MOUNTPOINT="$MOUNTPOINT"
MOUNT_UID=$UID_N
MOUNT_GID=$GID_N
EOF

cat > /etc/systemd/system/usb-gcode@.service <<'EOF'
[Unit]
Description=Mount USB stick for G-code (%I)
BindsTo=dev-%i.device
After=dev-%i.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/usb-gcode/usb-gcode.sh mount /dev/%I
ExecStop=/usr/local/lib/usb-gcode/usb-gcode.sh umount /dev/%I
EOF

cat > /etc/udev/rules.d/99-usb-gcode.rules <<'EOF'
# Any USB storage partition, on any port
ACTION=="add", SUBSYSTEM=="block", SUBSYSTEMS=="usb", ENV{DEVTYPE}=="partition", ENV{ID_FS_USAGE}=="filesystem", TAG+="systemd", ENV{SYSTEMD_WANTS}+="usb-gcode@%k.service"
# Sticks without a partition table (filesystem directly on the disk)
ACTION=="add", SUBSYSTEM=="block", SUBSYSTEMS=="usb", ENV{DEVTYPE}=="disk", ENV{ID_PART_TABLE_TYPE}=="", ENV{ID_FS_USAGE}=="filesystem", TAG+="systemd", ENV{SYSTEMD_WANTS}+="usb-gcode@%k.service"
EOF

echo "==> Folders"
sudo -u "$TARGET_USER" mkdir -p "$MOUNTPOINT" "$PRINTER_DATA/gcodes/Imported"

echo "==> Moonraker component"
ln -sfn "$LIB/usb_import.py" "$MOONRAKER_DIR/moonraker/components/usb_import.py"
CONF="$PRINTER_DATA/config/moonraker.conf"
if ! grep -qF "$BEGIN" "$CONF"; then
  cp -n "$CONF" "$CONF.bak-usbgcode"
  {
    printf '\n%s\n' "$BEGIN"
    printf '[usb_import]\nusb_dir: USB\nimport_dir: Imported\n'
    # Updates from Mainsail, if this came from a git clone with an origin
    if ORIGIN="$(sudo -u "$TARGET_USER" git -C "$SRC" remote get-url origin 2>/dev/null)"; then
      BRANCH="$(sudo -u "$TARGET_USER" git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
      printf '\n[update_manager print-from-usb-klipper]\ntype: git_repo\npath: %s\norigin: %s\nprimary_branch: %s\nmanaged_services: klipper moonraker\ninstall_script: install.sh\n' \
        "$SRC" "$ORIGIN" "$BRANCH"
    fi
    printf '%s\n' "$END"
  } >> "$CONF"
fi

echo "==> Klipper macro"
install -m 644 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
  "$SRC/src/usb_import.cfg" "$PRINTER_DATA/config/usb_import.cfg"
PCFG="$PRINTER_DATA/config/printer.cfg"
if ! grep -q 'include usb_import.cfg' "$PCFG"; then
  cp -n "$PCFG" "$PCFG.bak-usbgcode"
  # At the top: the end of the file belongs to Klipper's SAVE_CONFIG block
  sed -i '1i [include usb_import.cfg]' "$PCFG"
fi

echo "==> Activating"
systemctl daemon-reload
udevadm control --reload

if [[ $FIRST -eq 1 && $RESTART -eq 1 ]]; then
  systemctl restart moonraker klipper
  echo "Installed. Klipper and Moonraker were restarted."
else
  echo "Installed/updated. Unless this ran from the Mainsail update manager,"
  echo "restart Moonraker and Klipper to apply the changes."
fi
