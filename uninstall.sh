#!/usr/bin/env bash
# Removes everything install.sh added. Files already imported into
# gcodes/Imported are NOT deleted.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then exec sudo -E "$0" "$@"; fi

# True while a print is running/paused (restarting Klipper would abort it)
is_printing() {
  command -v curl >/dev/null || return 1
  local st
  st="$(curl -s --max-time 3 'http://127.0.0.1:7125/printer/objects/query?print_stats=state' \
        | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p')"
  [[ "$st" == printing || "$st" == paused ]]
}

if [[ "${1:-}" != "--force" ]] && is_printing; then
  echo "A print is in progress. Uninstalling restarts Klipper and would abort it." >&2
  echo "Run again when the printer is idle (or use --force)." >&2
  exit 1
fi

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
rm -rf /usr/local/lib/usb-gcode "$PRINTER_DATA/.usb_import_tmp"
rmdir "$PRINTER_DATA/gcodes/USB" 2>/dev/null || true   # only removed if empty

sed -i '/# >>> usb-gcode >>>/,/# <<< usb-gcode <<</d' "$PRINTER_DATA/config/moonraker.conf"
sed -i '/^\[include usb_import.cfg\]$/d' "$PRINTER_DATA/config/printer.cfg"

systemctl daemon-reload
udevadm control --reload
systemctl restart moonraker klipper
echo "Removed. The ~/print-from-usb-klipper folder and gcodes/Imported were not deleted."
