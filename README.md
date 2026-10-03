# Print from USB (Klipper)

Print G-code files from a USB stick on Klipper + Moonraker machines, the way a
commercial printer does. Works with Mainsail, Fluidd and KlipperScreen.

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

## Install

```
sudo apt-get update && sudo apt-get install -y git && cd ~ && git clone https://github.com/lrafa97/print-from-usb-klipper.git && ./print-from-usb-klipper/install.sh
```

For a different layout:
`PRINTER_DATA=/path MOONRAKER_DIR=/path ./print-from-usb-klipper/install.sh`

The installer backs up `printer.cfg` and `moonraker.conf` before touching them,
and restarts Klipper and Moonraker on the first install (do not run it in the
middle of a print).

## Update

From Mainsail (Machine > Update Manager > print-from-usb-klipper), or:

```
cd ~/print-from-usb-klipper && git pull && ./install.sh
```

## Uninstall

```
~/print-from-usb-klipper/uninstall.sh
```

Files already imported into `gcodes/Imported` are kept.

## How it works

1. A udev rule detects any USB storage partition and starts a small systemd
   service for it, which mounts it read-only. The service is bound to the
   device, so the stick is unmounted automatically when it is removed.
2. A Klipper macro overrides `SDCARD_PRINT_FILE` (the command Mainsail and
   KlipperScreen use to start a print). Paths starting with `USB/` are handed to
   Moonraker; everything else goes to the original command untouched.
3. A Moonraker component (`usb_import`) copies the file in a worker thread,
   writes it to a temporary name, syncs it to disk, checks the size, and only
   then renames it. After that it starts the print from the local copy and
   posts progress messages to the console.

## What gets installed

| Location | What |
|---|---|
| `/etc/udev/rules.d/99-usb-gcode.rules` | detects the stick on any port |
| `/etc/systemd/system/usb-gcode@.service` | mounts / unmounts the stick |
| `/usr/local/lib/usb-gcode/` | scripts run as root (a root-owned copy, not editable by the user) |
| `moonraker/components/usb_import.py` | copies the file and starts the print |
| `config/usb_import.cfg` | macro that intercepts `SDCARD_PRINT_FILE` for `USB/...` |
| `moonraker.conf`, `printer.cfg` | a block marked `usb-gcode` and one `[include]` line |

## Troubleshooting

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
- Early version: feedback and issues are welcome.
