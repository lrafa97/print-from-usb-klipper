# Print from USB (Klipper)

Print G-code files from a USB stick on Klipper + Moonraker machines, the way a
commercial printer does. Built for Mainsail and KlipperScreen; it hooks the
standard Klipper print command, so other front ends such as Fluidd should work
too (see [Status](#status)).

- The stick is mounted **read-only** at `gcodes/USB`, on **any USB port**, with
  **any stick** (FAT32, exFAT, NTFS, ext4). No configuration per stick.
- The user browses the stick in Mainsail or KlipperScreen and picks a file.
- When printing, **only that file** is copied to `gcodes/Imported` (verified,
  atomic write) and the print runs from the local copy. Once the print has
  started, the stick can be pulled out without affecting it.
- Copies accumulate. Identical files are not duplicated; same name with
  different content gets a suffix (`_1`).
- Normal uploads through the web interface keep working exactly as before.

## Requirements

- Raspberry Pi OS / Debian-based system with systemd
- Klipper and Moonraker installed in the default layout (`~/printer_data`,
  `~/moonraker`), for example via KIAUH
- A kernel with exFAT and NTFS support (any recent Raspberry Pi OS)
- No other USB automounter: if the `usbmount` package is present, the installer
  removes it, because it conflicts (reboot once afterwards)

## Install

```
(command -v git >/dev/null || (sudo apt-get update && sudo apt-get install -y git)) && cd ~ && git clone https://github.com/lrafa97/print-from-usb-klipper.git && ./print-from-usb-klipper/install.sh
```

Git is only installed if it is missing, so a broken or outdated apt repository
(common on end-of-life Raspberry Pi OS releases) does not stop the install.
If the `print-from-usb-klipper` folder already exists, use the update commands
below instead.

For a different layout:
`PRINTER_DATA=/path MOONRAKER_DIR=/path ./print-from-usb-klipper/install.sh`

The installer backs up `printer.cfg` and `moonraker.conf` before touching them,
and restarts Klipper and Moonraker on the first install. If a print is in
progress it installs everything but skips the restart and tells you to restart
Klipper when the printer is idle.

## Update

From Mainsail: Machine > Update Manager > refresh, then update
*print-from-usb-klipper*. The Moonraker component is linked to the cloned
repository, so the update replaces its code, and the managed restart of Klipper
and Moonraker loads it.

The system-side files (mount script, udev rule, Klipper macro) are copies that
change rarely. After an update, run `./doctor.sh`: if it reports that one of
them differs from the repository, run `./install.sh` (and restart Klipper if it
says so).

Manual update:

```
cd ~/print-from-usb-klipper && git pull && ./install.sh
sudo systemctl restart moonraker
```

## Uninstall

```
~/print-from-usb-klipper/uninstall.sh
```

This removes everything the installer added and restarts Klipper and Moonraker,
so both go back to their previous configuration. It refuses to run while a
print is in progress (`--force` overrides that).

Kept on purpose: the files in `gcodes/Imported` (they belong to the user), the
`*.bak-usbgcode` backups and the cloned folder. A removed `usbmount` package is
not reinstalled.

Run the uninstaller **before** deleting the cloned folder: the Moonraker
component is linked to it.

## How it works

1. A udev rule detects any USB storage partition and starts a small systemd
   service for it, which mounts it read-only. The service is bound to the
   device, so the stick is unmounted automatically when it is removed.
2. A Klipper macro overrides `SDCARD_PRINT_FILE` (the command Mainsail and
   KlipperScreen use to start a print). Paths starting with `USB/` are handed to
   Moonraker; everything else goes to the original command untouched.
3. A Moonraker component (`usb_import`) copies the file in a worker thread to a
   temporary file outside the watched folders, syncs it to disk, checks the
   size, and only then renames it into `gcodes/Imported`, so the web interface
   sees it appear as a normal new file. After that it starts the print from the
   local copy and posts progress messages to the console.
4. The same component watches the mount state and tells the web interface to
   refresh the `USB` folder when a stick is inserted or removed.

## What gets installed

| Location | What |
|---|---|
| `/etc/usb-gcode.conf` | mount point and owner used by the mount script |
| `/etc/udev/rules.d/99-usb-gcode.rules` | detects the stick on any port |
| `/etc/systemd/system/usb-gcode@.service` | mounts / unmounts the stick |
| `/usr/local/lib/usb-gcode/` | the mount script run as root (a root-owned copy, not editable by the user) |
| `moonraker/components/usb_import.py` | symlink to `src/usb_import.py` in the cloned repo: copies the file and starts the print |
| `config/usb_import.cfg` | macro that intercepts `SDCARD_PRINT_FILE` for `USB/...` |
| `moonraker.conf`, `printer.cfg` | a block marked `usb-gcode` and one `[include]` line |
| `printer_data/.usb_import_tmp/` | scratch folder for files being copied |

## Existing setups and conflicts

The installer checks your system before changing anything:

- **Another `SDCARD_PRINT_FILE` macro** in your Klipper config: the installer
  stops and changes nothing (two definitions would stop Klipper from starting).
  Merge or remove the old one, then run it again.
- **`usbmount` installed:** removed automatically (it mounts sticks inside udev's
  private namespace, which blocks this tool). Reboot once afterwards.
- **Other automounters** (udisks2 desktop automount, autofs, `/etc/fstab`
  entries for USB): not removed, because they are often needed for other
  reasons. `./doctor.sh` points them out if they mount the same stick.
- **Files already in `gcodes/USB`:** kept, but hidden while a stick is mounted.
- After the first install the script waits for Klipper to report *ready*. If it
  does not, it tells you and you can run `./uninstall.sh`; backups of the edited
  files are saved as `*.bak-usbgcode`.

Run `./doctor.sh` at any time for a read-only health report (install state,
services, conflicts, sticks, recent mount log). Paste its output when asking
for help.

## Troubleshooting

Start with `./doctor.sh`, then dig deeper if needed:

```
journalctl -t usb-gcode -n 30                  # stick mounting
findmnt ~/printer_data/gcodes/USB              # is the stick mounted?
tail -n 50 ~/printer_data/logs/moonraker.log   # copy and print start
```

## Limitations

- One stick at a time (a single mount point); with several partitions only the
  first one is mounted.
- Pulling the stick during the few seconds of the copy cancels the print start
  with an error message. After the print has started it is safe.
- KlipperScreen only updates a folder it is showing from per-file changes. If a
  stick is inserted or removed while the `USB` folder is already open there, tap
  the refresh button in the file list (Mainsail refreshes by itself). Opening the
  folder after inserting the stick always shows the right content. Tapping a
  file of a stick that was removed does not start anything and shows an error.

## Status

Early version. Tested on Raspberry Pi OS 11 (Bullseye), Klipper + Moonraker,
with Mainsail and KlipperScreen and FAT32 sticks. Fluidd uses the same Klipper
print command but has not been tested yet. Feedback and issues are welcome.
