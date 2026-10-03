#!/usr/bin/env bash
# Removes everything install.sh added. Files already imported into
# gcodes/Imported are NOT deleted.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then exec sudo -E "$0" "$@"; fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || {
  echo "Use TARGET_USER=<name>." >&2; exit 1; }
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
PRINTER_DATA="${PRINTER_DATA:-$HOME_DIR/printer_data}"
MOONRAKER_DIR="${MOONRAKER_DIR:-$HOME_DIR/moonraker}"

# Unmount any stick that is still mounted
systemctl stop 'usb-gcode@*.service' 2>/dev/null || true

rm -f /etc/udev/rules.d/99-usb-gcode.rules \
      /etc/systemd/system/usb-gcode@.service \
      /etc/usb-gcode.conf \
      "$MOONRAKER_DIR/moonraker/components/usb_import.py" \
      "$PRINTER_DATA/config/usb_import.cfg"
rm -rf /usr/local/lib/usb-gcode

sed -i '/# >>> usb-gcode >>>/,/# <<< usb-gcode <<</d' "$PRINTER_DATA/config/moonraker.conf"
sed -i '/^\[include usb_import.cfg\]$/d' "$PRINTER_DATA/config/printer.cfg"

systemctl daemon-reload
udevadm control --reload
systemctl restart moonraker klipper
echo "Removed. The ~/print-from-usb-klipper folder and gcodes/Imported were not deleted."
