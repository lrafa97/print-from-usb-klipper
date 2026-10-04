#!/usr/bin/env bash
# Health report for print-from-usb-klipper. Read-only: it changes nothing.
#   ./doctor.sh
# Paste the whole output when asking for help.
set -uo pipefail

ok()   { printf '  [ OK ]  %s\n' "$*"; }
warn() { printf '  [WARN]  %s\n' "$*"; }
bad()  { printf '  [FAIL]  %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF=/etc/usb-gcode.conf
HOME_DIR="${HOME}"
PRINTER_DATA="${PRINTER_DATA:-$HOME_DIR/printer_data}"
MOONRAKER_DIR="${MOONRAKER_DIR:-$HOME_DIR/moonraker}"
MOUNTPOINT=""

head_ "Installation"
if [[ -f "$CONF" ]]; then
  # shellcheck source=/dev/null
  source "$CONF"; ok "$CONF (mount point: $MOUNTPOINT)"
else
  bad "$CONF missing: run ./install.sh"
fi
[[ -f /etc/udev/rules.d/99-usb-gcode.rules ]]   && ok "udev rule"        || bad "udev rule missing"
[[ -f /etc/systemd/system/usb-gcode@.service ]] && ok "systemd service"  || bad "systemd service missing"
if [[ -x /usr/local/lib/usb-gcode/usb-gcode.sh ]]; then
  cmp -s "$SRC/src/usb-gcode.sh" /usr/local/lib/usb-gcode/usb-gcode.sh \
    && ok "mount script (up to date)" \
    || warn "mount script differs from the repo: run ./install.sh"
else
  bad "mount script missing"
fi
target="$(readlink -f "$MOONRAKER_DIR/moonraker/components/usb_import.py" 2>/dev/null || true)"
if [[ "$target" == "$SRC/src/usb_import.py" ]]; then
  ok "Moonraker component linked to this repo"
else
  bad "Moonraker component not linked to $SRC (run ./install.sh)"
fi
if [[ -f "$PRINTER_DATA/config/usb_import.cfg" ]]; then
  cmp -s "$SRC/src/usb_import.cfg" "$PRINTER_DATA/config/usb_import.cfg" \
    && ok "Klipper macro (up to date)" \
    || warn "Klipper macro differs from the repo: run ./install.sh, then restart Klipper"
else
  bad "Klipper macro file missing"
fi
grep -q 'usb-gcode >>>' "$PRINTER_DATA/config/moonraker.conf" 2>/dev/null \
  && ok "moonraker.conf block" || bad "moonraker.conf block missing"
grep -q 'include usb_import.cfg' "$PRINTER_DATA/config/printer.cfg" 2>/dev/null \
  && ok "printer.cfg include" || bad "printer.cfg include missing"

repo_ver="$(cat "$SRC/VERSION" 2>/dev/null || echo unknown)"
loaded_ver="$(grep -a -o 'usb_import: version [^ ]*' "$PRINTER_DATA/logs/moonraker.log" 2>/dev/null | tail -n1 | awk '{print $3}')"
if [[ -z "$loaded_ver" ]]; then
  warn "repo version $repo_ver; Moonraker has not logged a loaded version yet"
elif [[ "$loaded_ver" == "$repo_ver" ]]; then
  ok "version $repo_ver (repo = loaded by Moonraker)"
else
  bad "repo is $repo_ver but Moonraker loaded $loaded_ver: restart Moonraker"
fi

head_ "Services"
MLOG="$PRINTER_DATA/logs/moonraker.log"
if systemctl is-active --quiet moonraker; then
  ok "moonraker running"
  if grep -aq "Component (usb_import) loaded" "$MLOG" 2>/dev/null; then
    ok "usb_import component loaded"
  else
    bad "usb_import component not loaded: see $MLOG"
  fi
else
  bad "moonraker not running"
fi
if command -v curl >/dev/null; then
  state="$(curl -s --max-time 3 http://127.0.0.1:7125/printer/info \
           | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p')"
  case "$state" in
    ready) ok "Klipper ready" ;;
    "")    warn "could not read Klipper state from Moonraker" ;;
    *)     bad "Klipper state: $state" ;;
  esac
fi

head_ "Touchscreen watchdog"
wd="$(grep -a 'usb_import: .*\(watchdog\|connected to Moonraker\|not connected\|nothing to do\|restarting it\|time window\)' "$MLOG" 2>/dev/null | tail -n1)"
msg="$(printf '%s' "$wd" | sed 's/.*usb_import: //')"
case "$wd" in
  "")                        warn "no watchdog activity logged yet (Moonraker just started?)" ;;
  *"restarting it"*)         warn "$msg (the screen had lost its connection)" ;;
  *"not connected"*)         warn "$msg" ;;
  *"is connected to Moonraker"*) ok "$msg" ;;
  *"nothing to do"*)         ok "$msg" ;;
  *)                         warn "$msg" ;;   # armed / off / disabled / time window
esac
if command -v curl >/dev/null; then
  mwarn="$(curl -s --max-time 3 http://127.0.0.1:7125/server/info | grep -o 'usb-gcode: [^"]*')"
  [[ -n "$mwarn" ]] && while IFS= read -r line; do warn "Moonraker warning: $line"; done <<< "$mwarn"
fi

head_ "Possible conflicts"
for pkg in usbmount autofs; do
  dpkg -s "$pkg" >/dev/null 2>&1 && bad "package '$pkg' installed (conflicts, the installer removes usbmount)"
done
for svc in udisks2 devmon@pi; do
  systemctl is-active --quiet "$svc" 2>/dev/null && warn "$svc is running (can automount sticks; only a problem if it mounts the same stick)"
done
grep -nE '^[^#]*(/dev/sd|usb)' /etc/fstab 2>/dev/null | sed 's/^/  fstab: /' | grep . >/dev/null \
  && { warn "USB-related lines in /etc/fstab:"; grep -nE '^[^#]*(/dev/sd|usb)' /etc/fstab | sed 's/^/          /'; }
other="$(grep -rIliE '^\[gcode_macro[[:space:]]+SDCARD_PRINT_FILE\]' "$PRINTER_DATA/config" --include='*.cfg' 2>/dev/null | grep -v '/usb_import\.cfg$')"
[[ -n "$other" ]] && bad "SDCARD_PRINT_FILE also defined in: $other"
[[ -z "$other" ]] && ok "no other SDCARD_PRINT_FILE macro"

head_ "USB sticks"
found=0
while read -r name type fstype; do
  [[ "$type" =~ ^(part|disk)$ && -n "${fstype:-}" ]] || continue
  udevadm info -q property -n "/dev/$name" 2>/dev/null | grep -qx 'ID_BUS=usb' || continue
  found=1
  where="$(findmnt -rn -S "/dev/$name" -o TARGET,OPTIONS | head -n1)"
  printf '  /dev/%s  (%s)  mounted: %s\n' "$name" "$fstype" "${where:-no}"
done < <(lsblk -rno NAME,TYPE,FSTYPE 2>/dev/null)
[[ $found -eq 0 ]] && warn "no USB storage with a filesystem detected (stick inserted?)"
if [[ -n "$MOUNTPOINT" ]]; then
  findmnt -rn "$MOUNTPOINT" >/dev/null 2>&1 \
    && ok "stick mounted at $MOUNTPOINT" || warn "nothing mounted at $MOUNTPOINT"
fi

head_ "Versions"
echo "  $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown OS}"), kernel $(uname -r)"
echo "  python3: $(python3 --version 2>&1)"
[[ -x "$HOME_DIR/moonraker-env/bin/python" ]] && echo "  moonraker-env: $("$HOME_DIR/moonraker-env/bin/python" --version 2>&1)"

head_ "Recent mount log"
journalctl -t usb-gcode -n 10 --no-pager 2>/dev/null || echo "  (no access to the journal)"
echo
