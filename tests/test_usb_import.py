"""Tests for src/usb_import.py using a fake Moonraker. Run from the repo root:

    python3 -m unittest discover -s tests -v

No Moonraker, Klipper or hardware needed.
"""
import asyncio
import os
import pathlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
import usb_import  # noqa: E402


class ServerError(Exception):
    pass


class FakeServer:
    error = ServerError

    def __init__(self, components=None):
        self.components = components or {}
        self.warnings = {}
        self.methods = {}

    def register_remote_method(self, name, cb):
        self.methods[name] = cb

    def lookup_component(self, name):
        if name not in self.components:
            raise ServerError(name)
        return self.components[name]

    def add_warning(self, msg, warn_id=None, log=True, exc_info=None):
        self.warnings[warn_id] = msg
        return warn_id


class FakeConfig:
    def __init__(self, server, **opts):
        self.server, self.opts = server, opts

    def get_server(self):
        return self.server

    def get(self, key, default=None):
        return self.opts.get(key, default)

    def getfloat(self, key, default=None, above=None):
        return float(self.opts.get(key, default))


class FakeFileManager:
    def __init__(self, gcodes, config):
        self.dirs = {"gcodes": str(gcodes), "config": str(config)}

    def get_directory(self, root):
        return self.dirs[root]


class FakeKlippyApis:
    def __init__(self):
        self.gcodes, self.started = [], []

    async def run_gcode(self, script):
        self.gcodes.append(script)

    async def start_print(self, filename):
        self.started.append(filename)


class FakeMachine:
    def __init__(self, state="active", available=True, fail=False):
        self.info = {
            "available_services": ["KlipperScreen"] if available else [],
            "service_state": {"KlipperScreen": {"active_state": state}},
        }
        self.actions, self.fail = [], fail

    def get_system_info(self):
        return self.info

    async def do_service_action(self, action, name):
        if self.fail:
            raise ServerError("denied")
        self.actions.append((action, name))


class FakeWebsockets:
    def __init__(self, connected=False):
        self.connected = connected

    def get_clients_by_name(self, name):
        return [object()] if self.connected and name == "KlipperScreen" else []


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.gcodes = self.tmp / "printer_data" / "gcodes"
        self.cfg = self.tmp / "printer_data" / "config"
        (self.gcodes / "USB").mkdir(parents=True)
        self.cfg.mkdir(parents=True)
        self.kapis = FakeKlippyApis()
        self.fm = FakeFileManager(self.gcodes, self.cfg)

    def make(self, machine=None, ws=None, **opts):
        comps = {"file_manager": self.fm, "klippy_apis": self.kapis}
        if machine is not None:
            comps["machine"] = machine
        if ws is not None:
            comps["websockets"] = ws
        server = FakeServer(comps)
        return usb_import.UsbImport(FakeConfig(server, **opts)), server


class CopyTests(Base):
    def setUp(self):
        super().setUp()
        self.dest = self.gcodes / "Imported"
        self.dest.mkdir()
        self.tmpdir = self.tmp / "printer_data" / ".usb_import_tmp"
        self.tmpdir.mkdir()

    def run_copy(self, comp, src):
        return comp._copy_blocking(src, self.dest, self.tmpdir)

    def test_new_file_is_copied_and_tmp_is_clean(self):
        async def go():
            comp, _ = self.make()
            src = self.gcodes / "USB" / "a.gcode"
            src.write_bytes(b"G1 X1\n" * 1000)
            dest, reused = self.run_copy(comp, src)
            self.assertFalse(reused)
            self.assertEqual(dest.read_bytes(), src.read_bytes())
            self.assertEqual(list(self.tmpdir.iterdir()), [])
        asyncio.run(go())

    def test_identical_file_is_not_duplicated(self):
        async def go():
            comp, _ = self.make()
            src = self.gcodes / "USB" / "a.gcode"
            src.write_bytes(b"same")
            first, _ = self.run_copy(comp, src)
            second, reused = self.run_copy(comp, src)
            self.assertTrue(reused)
            self.assertEqual(first, second)
            self.assertEqual(len(list(self.dest.iterdir())), 1)
        asyncio.run(go())

    def test_same_name_different_content_gets_suffix(self):
        async def go():
            comp, _ = self.make()
            src = self.gcodes / "USB" / "a.gcode"
            src.write_bytes(b"version one")
            self.run_copy(comp, src)
            src.write_bytes(b"version two!")
            second, reused = self.run_copy(comp, src)
            self.assertFalse(reused)
            self.assertEqual(second.name, "a_1.gcode")
            src.write_bytes(b"version three!!")
            third, _ = self.run_copy(comp, src)
            self.assertEqual(third.name, "a_2.gcode")
        asyncio.run(go())

    def test_not_enough_space_is_reported(self):
        async def go():
            comp, _ = self.make()
            src = self.gcodes / "USB" / "a.gcode"
            src.write_bytes(b"x" * 100)
            fake = shutil._ntuple_diskusage(100, 100, 0)
            with mock.patch("shutil.disk_usage", return_value=fake):
                with self.assertRaises(usb_import.UsbImportError):
                    self.run_copy(comp, src)
            self.assertEqual(list(self.dest.iterdir()), [])
        asyncio.run(go())

    def test_unreadable_source_is_wrapped_and_leaves_nothing(self):
        async def go():
            comp, _ = self.make()
            bad = self.gcodes / "USB" / "gone.gcode"  # stick pulled: no file
            with self.assertRaises(usb_import.UsbImportError):
                self.run_copy(comp, bad)
            self.assertEqual(list(self.dest.iterdir()), [])
            self.assertEqual(list(self.tmpdir.iterdir()), [])
        asyncio.run(go())

    def test_failure_mid_copy_removes_partial_file(self):
        async def go():
            comp, _ = self.make()
            src = self.gcodes / "USB" / "a.gcode"
            src.write_bytes(b"x" * 10)
            with mock.patch("os.fsync", side_effect=OSError(5, "I/O error")):
                with self.assertRaises(usb_import.UsbImportError):
                    self.run_copy(comp, src)
            self.assertEqual(list(self.dest.iterdir()), [])
            self.assertEqual(list(self.tmpdir.iterdir()), [])
        asyncio.run(go())

    def test_stale_part_files_are_removed(self):
        async def go():
            comp, _ = self.make()
            (self.tmpdir / ".old.gcode.part").write_bytes(b"junk")
            src = self.gcodes / "USB" / "a.gcode"
            src.write_bytes(b"data")
            self.run_copy(comp, src)
            self.assertEqual(list(self.tmpdir.iterdir()), [])
        asyncio.run(go())


class PrintRequestTests(Base):
    def request(self, filename, mounted=True, create=True):
        async def go():
            comp, server = self.make()
            if create:
                f = self.gcodes / filename
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_bytes(b"G1 X1\n")
            with mock.patch("os.path.ismount", return_value=mounted):
                await comp._on_print_request(filename)
            return comp
        return asyncio.run(go())

    def test_happy_path_copies_then_starts_print_from_local_copy(self):
        self.request("USB/Cube v2.gcode")
        self.assertEqual(self.kapis.started, ["Imported/Cube v2.gcode"])
        self.assertTrue((self.gcodes / "Imported" / "Cube v2.gcode").is_file())
        self.assertTrue(any("copying" in g for g in self.kapis.gcodes))

    def test_path_traversal_is_rejected(self):
        (self.gcodes / "secret.gcode").write_bytes(b"x")
        self.request("USB/../secret.gcode", create=False)
        self.assertEqual(self.kapis.started, [])
        self.assertTrue(any("TYPE=error" in g for g in self.kapis.gcodes))

    def test_unsupported_extension_is_rejected(self):
        self.request("USB/notes.txt")
        self.assertEqual(self.kapis.started, [])
        self.assertTrue(any("unsupported" in g for g in self.kapis.gcodes))

    def test_stick_removed_reports_error_and_does_not_print(self):
        self.request("USB/a.gcode", mounted=False)
        self.assertEqual(self.kapis.started, [])
        self.assertTrue(any("stick removed" in g for g in self.kapis.gcodes))

    def test_error_messages_never_break_respond_syntax(self):
        self.assertEqual(usb_import._clean('a"b{c}\nd\\e'), "a b c  d e")


class ScreenWatchdogTests(Base):
    def run_watchdog(self, machine, ws, **opts):
        async def go():
            comp, server = self.make(machine=machine, ws=ws, **opts)
            with mock.patch.object(usb_import, "SCREEN_RECHECK", 0.01), \
                    mock.patch.object(usb_import, "SCREEN_WINDOW", 2.0):
                await comp._screen_check("KlipperScreen")
            return server
        return asyncio.run(go())

    def test_connected_screen_is_left_alone(self):
        m = FakeMachine()
        self.run_watchdog(m, FakeWebsockets(connected=True))
        self.assertEqual(m.actions, [])

    def test_stuck_screen_is_restarted_once_and_recovers(self):
        m, ws = FakeMachine(), FakeWebsockets(connected=False)
        orig = m.do_service_action

        async def restart_then_connect(action, name):
            await orig(action, name)
            ws.connected = True  # the restarted screen reconnects
        m.do_service_action = restart_then_connect
        server = self.run_watchdog(m, ws)
        self.assertEqual(m.actions, [("restart", "KlipperScreen")])
        self.assertEqual(server.warnings, {})

    def test_screen_that_never_connects_gets_two_restarts_then_a_warning(self):
        m = FakeMachine()
        server = self.run_watchdog(m, FakeWebsockets(connected=False))
        self.assertEqual(len(m.actions), usb_import.SCREEN_MAX_RESTARTS)
        self.assertIn("usb_import_screen", server.warnings)

    def test_stopped_screen_is_never_started(self):
        for state in ("inactive", "failed", "unknown"):
            m = FakeMachine(state=state)
            server = self.run_watchdog(m, FakeWebsockets(connected=False))
            self.assertEqual(m.actions, [], state)
            self.assertEqual(server.warnings, {}, state)

    def test_screen_still_starting_is_waited_for(self):
        m, ws = FakeMachine(state="activating"), FakeWebsockets(connected=True)

        async def go():
            comp, _ = self.make(machine=m, ws=ws)
            real_sleep = asyncio.sleep

            async def fast_sleep(delay, *a, **k):
                m.info["service_state"]["KlipperScreen"]["active_state"] = "active"
                await real_sleep(0)
            with mock.patch.object(usb_import.asyncio, "sleep", fast_sleep):
                await comp._screen_check("KlipperScreen")
        asyncio.run(go())
        self.assertEqual(m.actions, [])

    def test_service_not_installed_or_not_allowed_disables_watchdog(self):
        m = FakeMachine(available=False)
        self.run_watchdog(m, FakeWebsockets(connected=False))
        self.assertEqual(m.actions, [])

    def test_restart_refused_by_system_is_reported_not_retried(self):
        m = FakeMachine(fail=True)
        server = self.run_watchdog(m, FakeWebsockets(connected=False))
        self.assertIn("usb_import_screen", server.warnings)
        self.assertEqual(m.actions, [])

    def test_missing_components_do_not_crash(self):
        async def go():
            comp, _ = self.make()  # no machine / websockets
            await comp._screen_check("KlipperScreen")
        asyncio.run(go())

    def test_empty_service_name_disables_watchdog(self):
        async def go():
            comp, _ = self.make(screen_service="")
            await comp._screen_watchdog()
        asyncio.run(go())


class DriftTests(Base):
    def test_warning_only_when_installed_copies_differ(self):
        installed = self.tmp / "usb-gcode.sh"
        shutil.copy(ROOT / "src" / "usb-gcode.sh", installed)
        shutil.copy(ROOT / "src" / "usb_import.cfg", self.cfg / "usb_import.cfg")

        async def check():
            comp, server = self.make()
            with mock.patch.object(usb_import, "INSTALLED_MOUNT_SCRIPT", installed):
                comp._check_installed_files()
            return server.warnings

        self.assertEqual(asyncio.run(check()), {})
        (self.cfg / "usb_import.cfg").write_text("# old macro\n")
        warnings = asyncio.run(check())
        self.assertIn("usb_import_drift", warnings)
        self.assertIn("usb_import.cfg", warnings["usb_import_drift"])
        self.assertIn("install.sh", warnings["usb_import_drift"])

    def test_missing_installed_copy_is_reported(self):
        async def check():
            comp, server = self.make()
            with mock.patch.object(
                usb_import, "INSTALLED_MOUNT_SCRIPT", self.tmp / "nope.sh"
            ):
                comp._check_installed_files()
            return server.warnings
        self.assertIn("usb_import_drift", asyncio.run(check()))


if __name__ == "__main__":
    unittest.main()
