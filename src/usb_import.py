# Moonraker component: usb_import
#
# Called by the SDCARD_PRINT_FILE macro (see usb_import.cfg) when the file path
# starts with "USB/". Copies ONLY that file from the USB stick to internal
# storage, verifies it, and starts the print from the local copy.
# Once the print has started, the stick can be removed safely.
#
# moonraker.conf:
#   [usb_import]
#   usb_dir: USB            # folder (inside gcodes) where the stick is mounted
#   import_dir: Imported    # destination folder for the copies (they accumulate)
#   screen_service: KlipperScreen   # touchscreen service to keep connected
#                                   # (empty value disables the watchdog)
#   screen_check_delay: 40  # seconds after Moonraker starts before checking it
from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import pathlib
import shutil
from typing import TYPE_CHECKING, Optional, Tuple

if TYPE_CHECKING:
    from confighelper import ConfigHelper

CHUNK = 1024 * 1024
ALLOWED_EXT = {".gcode", ".gco", ".g"}
MIN_FREE_MARGIN = 64 * 1024 * 1024  # free space to keep after the copy
INSTALLED_MOUNT_SCRIPT = pathlib.Path("/usr/local/lib/usb-gcode/usb-gcode.sh")
SCREEN_RECHECK = 45.0       # seconds to wait after restarting the screen service
SCREEN_MAX_RESTARTS = 2     # restarts attempted per Moonraker start
SCREEN_WINDOW = 300.0       # give up watching this long after the first check


class UsbImportError(Exception):
    """Error with a message that is safe to show to the user."""


def _sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def _fmt_size(num: int) -> str:
    return f"{num / (1024 * 1024):.1f} MB"


def _clean(text: str) -> str:
    # RESPOND MSG="..." does not tolerate quotes, braces or line breaks
    for ch in '"{}\n\r\\':
        text = text.replace(ch, " ")
    return text


class UsbImport:
    def __init__(self, config: ConfigHelper) -> None:
        self.server = config.get_server()
        self.usb_dir = config.get("usb_dir", "USB").strip("/")
        self.import_dir = config.get("import_dir", "Imported").strip("/")
        self.screen_service = config.get("screen_service", "KlipperScreen").strip()
        self.screen_delay = config.getfloat("screen_check_delay", 40.0, above=4.0)
        self.lock = asyncio.Lock()
        self._log_version()
        self._watch_task: Optional[asyncio.Task] = None
        self._screen_task: Optional[asyncio.Task] = None
        self.server.register_remote_method(
            "usb_import_print", self._on_print_request
        )

    def _log_version(self) -> None:
        # Lets "doctor.sh" prove which code Moonraker is really running
        here = pathlib.Path(__file__).resolve()
        try:
            version = (here.parent.parent / "VERSION").read_text().strip()
        except OSError:
            version = "unknown"
        logging.info(f"usb_import: version {version} loaded from {here}")

    # ------------------------------------------- mount watcher / UI refresh
    async def component_init(self) -> None:
        self._check_installed_files()
        self._watch_task = asyncio.create_task(self._watch_mount())
        self._screen_task = asyncio.create_task(self._screen_watchdog())

    async def close(self) -> None:
        for task in (self._watch_task, self._screen_task):
            if task is not None:
                task.cancel()

    # ------------------------------------------------ installed files check
    def _check_installed_files(self) -> None:
        # The mount script and the Klipper macro are copies made by install.sh.
        # An update can change the repository copy; tell the user when the
        # installed copies are behind instead of silently running old ones.
        try:
            repo = pathlib.Path(__file__).resolve().parent.parent
            fm = self.server.lookup_component("file_manager")
            cfg_dir = pathlib.Path(str(fm.get_directory("config")))
            pairs = [
                (repo / "src" / "usb-gcode.sh", INSTALLED_MOUNT_SCRIPT),
                (repo / "src" / "usb_import.cfg", cfg_dir / "usb_import.cfg"),
            ]
            stale = []
            for src, dst in pairs:
                if not src.is_file():
                    continue
                if not dst.is_file() or _sha256(src) != _sha256(dst):
                    stale.append(dst.name)
            if stale:
                self.server.add_warning(
                    f"usb-gcode: {', '.join(stale)} differ from the repository. "
                    f"Run: cd {repo} && ./install.sh",
                    warn_id="usb_import_drift",
                )
        except Exception:
            logging.exception("usb_import: installed files check failed")

    # ------------------------------------------------- touchscreen watchdog
    # KlipperScreen retries a lost connection only a few times and then stays
    # stuck until its service is restarted. After Moonraker (re)starts, make
    # sure the screen is really connected; if it is running but not connected,
    # restart just that service.
    async def _screen_watchdog(self) -> None:
        name = self.screen_service
        if not name:
            logging.info("usb_import: screen watchdog disabled")
            return
        logging.info(
            f"usb_import: screen watchdog armed for {name} "
            f"(first check in {self.screen_delay:.0f} s)"
        )
        try:
            await asyncio.sleep(self.screen_delay)
            await self._screen_check(name)
        except asyncio.CancelledError:
            raise
        except Exception:
            logging.exception("usb_import: screen watchdog error")

    def _screen_state(self, machine, name: str) -> str:
        info = machine.get_system_info()
        return info.get("service_state", {}).get(name, {}).get(
            "active_state", "unknown"
        )

    async def _screen_check(self, name: str) -> None:
        try:
            machine = self.server.lookup_component("machine")
            clients = self.server.lookup_component("websockets")
        except self.server.error:
            logging.info("usb_import: screen watchdog off (components missing)")
            return
        if name not in machine.get_system_info().get("available_services", []):
            logging.info(
                f"usb_import: screen watchdog off ({name} is not an installed "
                "service allowed in moonraker.asvc)"
            )
            return

        loop = asyncio.get_running_loop()
        deadline = loop.time() + SCREEN_WINDOW
        restarts = 0
        while loop.time() < deadline:
            state = self._screen_state(machine, name)
            if state == "activating":
                await asyncio.sleep(10.0)
                continue
            if state != "active":
                logging.info(f"usb_import: {name} is '{state}', nothing to do")
                return
            if clients.get_clients_by_name(name):
                logging.info(f"usb_import: {name} is connected to Moonraker")
                return
            if restarts >= SCREEN_MAX_RESTARTS:
                self.server.add_warning(
                    f"usb-gcode: {name} is running but could not connect to "
                    f"Moonraker after {restarts} restarts. "
                    f"Try: sudo systemctl restart {name}",
                    warn_id="usb_import_screen",
                )
                return
            restarts += 1
            logging.warning(
                f"usb_import: {name} is running but not connected to "
                f"Moonraker, restarting it ({restarts}/{SCREEN_MAX_RESTARTS})"
            )
            try:
                await machine.do_service_action("restart", name)
            except Exception as e:
                self.server.add_warning(
                    f"usb-gcode: could not restart {name}: {e}",
                    warn_id="usb_import_screen",
                )
                return
            await asyncio.sleep(SCREEN_RECHECK)
        logging.warning(f"usb_import: stopped watching {name} (time window over)")

    @staticmethod
    def _mount_state(path: pathlib.Path) -> Tuple[bool, int]:
        try:
            return os.path.ismount(path), os.stat(path).st_dev
        except OSError:
            return False, 0

    async def _watch_mount(self) -> None:
        # Mounting a disk produces no inotify events, so Mainsail/KlipperScreen
        # would keep showing a stale USB folder. Poll the mount state (one
        # stat per second) and tell the clients to refresh when it changes.
        last: Optional[Tuple[bool, int]] = None
        while True:
            try:
                usb_root = self._gcode_root() / self.usb_dir
                state = self._mount_state(usb_root)
                if last is not None and state != last:
                    await self._refresh_usb_folder(usb_root)
                last = state
            except asyncio.CancelledError:
                raise
            except Exception:
                logging.exception("usb_import: mount watcher error")
            await asyncio.sleep(1.0)

    async def _refresh_usb_folder(self, usb_root: pathlib.Path) -> None:
        # Mainsail/Fluidd rebuild a folder (and re-request its contents from
        # Moonraker) when they are told it was deleted and created again.
        fm = self.server.lookup_component("file_manager")
        path = str(usb_root)
        try:
            fm._sched_changed_event("delete_dir", "gcodes", path, immediate=True)
            await asyncio.sleep(0.3)
            fm._sched_changed_event("create_dir", "gcodes", path, immediate=True)
        except Exception:
            logging.exception("usb_import: could not send file list refresh")

    # ------------------------------------------------------------ helpers
    def _gcode_root(self) -> pathlib.Path:
        fm = self.server.lookup_component("file_manager")
        return pathlib.Path(str(fm.get_directory("gcodes"))).resolve()

    async def _respond(self, msg: str, error: bool = False) -> None:
        kapis = self.server.lookup_component("klippy_apis")
        kind = " TYPE=error" if error else ""
        try:
            await kapis.run_gcode(f'RESPOND{kind} MSG="{_clean(msg)}"')
        except self.server.error as e:
            logging.info(f"usb_import: could not notify Klipper: {e}")

    # ----------------------------------------------------------- handler
    async def _on_print_request(self, filename: str = "") -> None:
        if self.lock.locked():
            await self._respond("USB: a copy is already in progress", True)
            return
        async with self.lock:
            try:
                await self._import_and_print(filename)
            except UsbImportError as e:
                logging.info(f"usb_import: {e}")
                await self._respond(f"USB: {e}", True)
            except Exception:
                logging.exception("usb_import: unexpected error")
                await self._respond(
                    "USB: unexpected error, see moonraker.log", True
                )

    async def _import_and_print(self, filename: str) -> None:
        root = self._gcode_root()
        usb_root = (root / self.usb_dir).resolve()
        src = (root / filename).resolve()

        # Security: the file must really be inside the USB folder
        if usb_root not in src.parents:
            raise UsbImportError("invalid path")
        if src.suffix.lower() not in ALLOWED_EXT:
            raise UsbImportError("unsupported file type")
        if not os.path.ismount(usb_root) or not src.is_file():
            raise UsbImportError("file not found, was the stick removed?")

        dest_dir = root / self.import_dir
        dest_dir.mkdir(parents=True, exist_ok=True)

        size = src.stat().st_size
        await self._respond(f"USB: copying {src.name} ({_fmt_size(size)})")

        loop = asyncio.get_running_loop()
        dest, reused = await loop.run_in_executor(
            None, self._copy_blocking, src, dest_dir, self._tmp_dir(root, dest_dir)
        )

        note = "already imported, not duplicated" if reused else "copy complete"
        await self._respond(
            f"USB: {note}, starting print (you can remove the stick now)"
        )
        kapis = self.server.lookup_component("klippy_apis")
        await kapis.start_print(f"{self.import_dir}/{dest.name}")

    def _tmp_dir(self, root: pathlib.Path, dest_dir: pathlib.Path) -> pathlib.Path:
        # The temporary file lives OUTSIDE the directories Moonraker watches.
        # Renaming it into place then looks like a brand-new file to Moonraker
        # (-> normal "file created" update in the web UI). A rename inside the
        # watched tree is reported as "move_file" from a path the UI never knew.
        tmp_dir = root.parent / ".usb_import_tmp"
        try:
            tmp_dir.mkdir(exist_ok=True)
            if os.stat(tmp_dir).st_dev == os.stat(dest_dir).st_dev:
                return tmp_dir  # same filesystem: rename stays atomic
        except OSError:
            pass
        return dest_dir

    # ------------------------------------------------- copy (worker thread)
    def _copy_blocking(
        self, src: pathlib.Path, dest_dir: pathlib.Path, tmp_dir: pathlib.Path
    ) -> Tuple[pathlib.Path, bool]:
        try:
            # Only one copy runs at a time: anything left here is stale
            for stale in tmp_dir.glob(".*.part"):
                try:
                    stale.unlink()
                except FileNotFoundError:
                    pass
            size = src.stat().st_size
            src_hash: Optional[str] = None

            # Pick a name: reuse an identical copy, or the first free name
            final: Optional[pathlib.Path] = None
            n = 0
            while final is None:
                name = src.name if n == 0 else f"{src.stem}_{n}{src.suffix}"
                cand = dest_dir / name
                if not cand.exists():
                    final = cand
                elif cand.stat().st_size == size:
                    if src_hash is None:
                        src_hash = _sha256(src)
                    if _sha256(cand) == src_hash:
                        return cand, True
                n += 1

            free = shutil.disk_usage(dest_dir).free
            if free < size + MIN_FREE_MARGIN:
                raise UsbImportError(
                    f"not enough free space ({_fmt_size(free)} free)"
                )

            tmp = tmp_dir / f".{final.name}.part"
            copied = 0
            try:
                with open(src, "rb") as fin, open(tmp, "wb") as fout:
                    while True:
                        block = fin.read(CHUNK)
                        if not block:
                            break
                        fout.write(block)
                        copied += len(block)
                    fout.flush()
                    os.fsync(fout.fileno())
                if copied != size or tmp.stat().st_size != size:
                    raise UsbImportError("incomplete copy")
                if src.stat().st_size != size:
                    raise UsbImportError("file changed during the copy")
                os.replace(tmp, final)  # atomic: never visible half-written
                dfd = os.open(dest_dir, os.O_RDONLY)
                try:
                    os.fsync(dfd)
                finally:
                    os.close(dfd)
            finally:
                if tmp.exists():
                    tmp.unlink()
            return final, False
        except OSError as e:
            raise UsbImportError(
                f"read/write failed (stick removed?): {e.strerror}"
            ) from e


def load_component(config: ConfigHelper) -> UsbImport:
    return UsbImport(config)
