#!/usr/bin/env bash
# Installer for print-from-usb-klipper. Idempotent: safe to run several times.
#   ./install.sh [--no-restart]
# Optional environment variables: PRINTER_DATA, MOONRAKER_DIR, TARGET_USER,
# SCREEN_SERVICE (touchscreen service to keep connected, default KlipperScreen;
# set it empty to disable that watchdog)
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Elevates itself (the clone keeps the right owner, the install runs as root)
if [[ $EUID -ne 0 ]]; then exec sudo -E "$0" "$@"; fi

# True while a print is running/paused (restarting Klipper would abort it)
is_printing() {
  command -v curl >/dev/null || return 1
  local st
  st="$(curl -s --max-time 3 'http://127.0.0.1:7125/printer/objects/query?print_stats=state' \
        | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p')"
  [[ "$st" == printing || "$st" == paused ]]
}

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
BACKUP_DIR="$PRINTER_DATA/config/print-from-usb-klipper-backup"

# backup <file>: keep the FIRST (original) copy in the backup folder, named
# <file>.bak. Also migrates backups made by older versions next to the original.
backup() {
  local f="$1" base grp
  base="$(basename "$f")"; grp="$(id -gn "$TARGET_USER")"
  install -d -o "$TARGET_USER" -g "$grp" "$BACKUP_DIR"
  if [[ -f "$f.bak-usbgcode" ]]; then
    [[ -e "$BACKUP_DIR/$base.bak" ]] || mv "$f.bak-usbgcode" "$BACKUP_DIR/$base.bak"
    rm -f "$f.bak-usbgcode"
  fi
  [[ -e "$BACKUP_DIR/$base.bak" ]] || cp "$f" "$BACKUP_DIR/$base.bak"
  chown "$TARGET_USER:$grp" "$BACKUP_DIR/$base.bak"
}

SCREEN_SERVICE="${SCREEN_SERVICE-KlipperScreen}"
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

# Another config that already defines SDCARD_PRINT_FILE would make Klipper
# refuse to start (duplicate macro / rename_existing). Stop before touching anything.
CONFLICTS="$(grep -rIliE '^\[gcode_macro[[:space:]]+SDCARD_PRINT_FILE\]' "$PRINTER_DATA/config" \
             --include='*.cfg' 2>/dev/null | grep -v '/usb_import\.cfg$' || true)"
if [[ -n "$CONFLICTS" ]]; then
  echo "ERROR: SDCARD_PRINT_FILE is already defined in your Klipper config:" >&2
  echo "$CONFLICTS" | sed 's/^/  - /' >&2
  echo "This tool needs to override that command. Merge or remove the existing" >&2
  echo "macro first, then run the installer again. Nothing was changed." >&2
  exit 1
fi

# 'usbmount' (found on some printer images) mounts sticks inside udev's private
# mount namespace, which makes our own mount fail with "mount point busy".
if dpkg -s usbmount >/dev/null 2>&1; then
  echo "==> Removing 'usbmount' (conflicts with this tool)"
  apt-get purge -y usbmount
  umount /media/usb* 2>/dev/null || true
  echo "    Reboot once after the install so no stale mount is left behind."
fi

echo "==> System files"
# Copied to a root-owned location: root never executes anything the user can edit
install -d "$LIB"
install -m 755 "$SRC/src/usb-gcode.sh"  "$LIB/usb-gcode.sh"
rm -f "$LIB/usb_import.py"   # older versions kept a copy here

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

if ! mountpoint -q "$MOUNTPOINT" && [[ -n "$(ls -A "$MOUNTPOINT" 2>/dev/null)" ]]; then
  echo "WARNING: $MOUNTPOINT already contains files. They stay on disk but are"
  echo "         hidden while a USB stick is mounted there."
fi

echo "==> Moonraker component"
# Linked to the repo (runs as the normal user, like Moonraker itself): a git
# update from Mainsail replaces the code, and the managed restart loads it.
ln -sfn "$SRC/src/usb_import.py" "$MOONRAKER_DIR/moonraker/components/usb_import.py"
CONF="$PRINTER_DATA/config/moonraker.conf"
backup "$CONF"
# Drop any previous block (and trailing blank lines), then write a fresh one
sed -i '/# >>> usb-gcode >>>/,/# <<< usb-gcode <<</d' "$CONF"
sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$CONF"
{
  printf '\n%s\n' "$BEGIN"
  printf '[usb_import]\nusb_dir: USB\nimport_dir: Imported\nscreen_service: %s\nscreen_check_delay: 40\n' \
    "$SCREEN_SERVICE"
  # Updates from Mainsail, if this came from a git clone with an origin
  if ORIGIN="$(sudo -u "$TARGET_USER" git -C "$SRC" remote get-url origin 2>/dev/null)"; then
    # symbolic-ref prints nothing when detached/unavailable (rev-parse prints "HEAD")
    BRANCH="$(sudo -u "$TARGET_USER" git -C "$SRC" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    [[ -n "$BRANCH" ]] || BRANCH=main
    # The update manager component only loads when the base section exists
    if ! grep -rqE '^\[update_manager\][[:space:]]*$' "$PRINTER_DATA/config" \
         --include='*.conf' --include='*.cfg' 2>/dev/null; then
      printf '\n[update_manager]\n'
    fi
    printf '\n[update_manager print-from-usb-klipper]\ntype: git_repo\npath: %s\norigin: %s\nprimary_branch: %s\nmanaged_services: moonraker\n' \
      "$SRC" "$ORIGIN" "$BRANCH"
  fi
  printf '%s\n' "$END"
} >> "$CONF"

echo "==> Klipper macro"
MACRO_CHANGED=0
cmp -s "$SRC/src/usb_import.cfg" "$PRINTER_DATA/config/usb_import.cfg" 2>/dev/null || MACRO_CHANGED=1
install -m 644 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
  "$SRC/src/usb_import.cfg" "$PRINTER_DATA/config/usb_import.cfg"
PCFG="$PRINTER_DATA/config/printer.cfg"
backup "$PCFG"
if ! grep -q 'include usb_import.cfg' "$PCFG"; then
  # At the top: the end of the file belongs to Klipper's SAVE_CONFIG block
  sed -i '1i [include usb_import.cfg]' "$PCFG"
fi

echo "==> Activating"
systemctl daemon-reload
udevadm control --reload

if [[ $RESTART -eq 1 ]] && is_printing; then
  RESTART=0
  echo "A print is in progress: nothing was restarted. Restart Moonraker (and Klipper,"
  echo "if it is the first install or the macro changed) when the printer is idle."
fi

if [[ $RESTART -eq 1 ]]; then
  if [[ $FIRST -eq 1 ]]; then
    systemctl restart moonraker klipper   # first install: the macro needs Klipper
  else
    systemctl restart moonraker           # updates: the component only needs Moonraker
  fi
  echo "==> Waiting for Klipper to report ready (up to 60 s)"
  state=unknown
  if command -v curl >/dev/null; then
    for _ in $(seq 1 30); do
      sleep 2
      info="$(curl -s --max-time 2 http://127.0.0.1:7125/printer/info || true)"
      state="$(printf '%s' "$info" | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p')"
      [[ "$state" == ready || "$state" == error || "$state" == shutdown ]] && break
      state=unknown
    done
  fi
  case "$state" in
    ready)
      echo "Installed. Klipper is ready." ;;
    error|shutdown)
      echo "WARNING: Klipper reports '$state' after the install." >&2
      echo "$info" | sed -n 's/.*"state_message": *"\([^"]*\)".*/  \1/p' >&2
      echo "If this is caused by this tool, run ./uninstall.sh (backups: config/print-from-usb-klipper-backup)." >&2 ;;
    *)
      echo "Installed. Could not verify Klipper's state; check Mainsail." ;;
  esac
  if [[ $FIRST -eq 0 && $MACRO_CHANGED -eq 1 ]]; then
    echo "The Klipper macro changed: restart Klipper when the printer is idle."
  fi
else
  echo "Installed/updated without restarting. Restart Moonraker to apply the changes"
  echo "(and Klipper if it is the first install or the macro changed)."
fi
