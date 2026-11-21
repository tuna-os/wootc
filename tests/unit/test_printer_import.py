#!/usr/bin/env python3
"""wootc-printer-import: Windows printers → driverless CUPS queues (SPEC §4.6).

CUPS is faked by lpstat/lpadmin scripts on PATH that keep their queues in a
directory, and the network probe is replaced in-process, so every branch of
the state machine runs here; tests/migration/test-printers.sh proves the same
flow against a real cupsd.
"""
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

ROOT = Path(__file__).resolve().parents[2]
IMPORTER = ROOT / "payload" / "migration" / "wootc-printer-import"
MANIFEST = ROOT / "payload" / "migration" / "wootc-manifest"
SELECTION = ROOT / "payload" / "migration" / "wootc-selection"

FAKE_LPSTAT = r"""#!/usr/bin/env python3
import os, sys
d = os.environ["FAKE_CUPS"]
if os.path.exists(os.path.join(d, "down")):
    print("lpstat: Bad file descriptor", file=sys.stderr); sys.exit(1)
queues = [l.split(" ", 1) for l in open(os.path.join(d, "queues")).read().splitlines() if l]
arg = sys.argv[1]
if arg == "-r":
    print("scheduler is running")
elif arg == "-v":
    if not queues:
        print("lpstat: No destinations added.", file=sys.stderr); sys.exit(1)
    for q, uri in queues:
        print(f"device for {q}: {uri}")
elif arg == "-d":
    p = os.path.join(d, "default")
    print(f"system default destination: {open(p).read().strip()}" if os.path.exists(p)
          else "no system default destination")
"""

FAKE_LPADMIN = r"""#!/usr/bin/env python3
import os, sys
d = os.environ["FAKE_CUPS"]
with open(os.path.join(d, "calls"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
a = sys.argv[1:]
if a[0] == "-d":
    open(os.path.join(d, "default"), "w").write(a[1]); sys.exit(0)
q, uri = a[a.index("-p") + 1], a[a.index("-v") + 1]
fail = os.path.join(d, "fail")
if os.path.exists(fail):
    print(open(fail).read().strip(), file=sys.stderr); sys.exit(1)
open(os.path.join(d, "queues"), "a").write(f"{q} {uri}\n")
"""

WINDOWS = [
    {"name": "Office Laser 5eed", "portName": "127.0.0.2", "default": True, "shared": False,
     "portKind": "tcpip", "host": "127.0.0.2", "port": 9100, "protocol": "raw"},
    {"name": "Lab Printer 5eed", "portName": "IP_192.0.2.44", "default": False, "shared": False,
     "portKind": "tcpip", "host": "192.0.2.44", "port": 9100, "protocol": "raw"},
    {"name": "Label Printer 5eed", "portName": "LPT1:", "default": False, "shared": False,
     "portKind": "lpt"},
    {"name": "Microsoft Print to PDF", "portName": "PORTPROMPT:", "default": False,
     "shared": False, "portKind": "virtual"},
]


def load_importer():
    loader = importlib.machinery.SourceFileLoader("wootc_printer_import", str(IMPORTER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.cups = base / "cups"
        self.cups.mkdir()
        (self.cups / "queues").write_text("")
        bins = base / "bin"
        bins.mkdir()
        for name, body in (("lpstat", FAKE_LPSTAT), ("lpadmin", FAKE_LPADMIN)):
            (bins / name).write_text(body)
            (bins / name).chmod(0o755)
        self.selection_rc = 0
        (bins / "wootc-selection").write_text(
            '#!/bin/sh\nexit "$(cat "$FAKE_CUPS/selection-rc-$3" 2>/dev/null || cat "$FAKE_CUPS/selection-rc" 2>/dev/null || echo 0)"\n')
        (bins / "wootc-selection").chmod(0o755)
        self.host = base / "host"
        (self.host / "wootc" / "install").mkdir(parents=True)
        self.state = base / "var" / "lib" / "wootc" / "printers.json"
        self.env = {"FAKE_CUPS": str(self.cups), "PATH": f"{bins}{os.pathsep}{os.environ['PATH']}"}
        self.old_env = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)
        self.mod = load_importer()
        self.mod.SOURCE = str(self.host / "wootc" / "install" / "printers.json")
        self.mod.STATE = str(self.state)
        self.mod.chooser_user = lambda: "alice"
        self.reach = {"127.0.0.2": True}
        self.mod.reachable = lambda uri: (
            (True, "") if self.reach.get(uri.split("/")[2].rsplit(":", 1)[0])
            else (False, "no answer from test"))
        self.windows(WINDOWS)

    def tearDown(self):
        for k, v in self.old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def windows(self, printers):
        Path(self.mod.SOURCE).write_text(json.dumps({"schemaVersion": 1, "printers": printers}))

    def run_import(self):
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(self.mod.migrate(), 0)
        self.log = out.getvalue()
        return {r["name"]: r for r in json.loads(self.state.read_text())["printers"]}

    def calls(self):
        p = self.cups / "calls"
        return p.read_text().splitlines() if p.exists() else []

    def queues(self):
        return (self.cups / "queues").read_text().splitlines()


class Naming(unittest.TestCase):
    def setUp(self):
        self.mod = load_importer()

    def test_queue_name_sanitisation(self):
        s = self.mod.sanitize
        self.assertEqual(s("Office Laser 5eed"), "Office_Laser_5eed")
        self.assertEqual(s("HP LaserJet (2nd floor) / Room 3.14"), "HP_LaserJet_2nd_floor_Room_3_14")
        self.assertEqual(s("Café Drucker"), "Caf_Drucker")
        self.assertEqual(s("  !!!  "), "printer")
        self.assertEqual(len(s("x" * 300)), 127)

    def test_queue_names_are_unique_case_insensitively(self):
        names = self.mod.queue_names([{"name": "Lab A"}, {"name": "lab_a"}, {"name": "Lab-A"}, {"name": "Lab  A"}])
        self.assertEqual(names, ["Lab_A", "lab_a-2", "Lab-A", "Lab_A-3"])
        long = self.mod.queue_names([{"name": "y" * 200}, {"name": "y" * 201}])
        self.assertEqual([len(q) for q in long], [127, 127])
        self.assertTrue(long[1].endswith("-2"))

    def test_target_uri(self):
        t = self.mod.target_uri
        self.assertEqual(t({"portKind": "tcpip", "host": "127.0.0.2", "port": 9100}), "ipp://127.0.0.2:631/ipp/print")
        self.assertEqual(t({"portKind": "tcpip", "host": "fe80::1"}), "ipp://[fe80::1]:631/ipp/print")
        self.assertEqual(t({"portKind": "ipp", "uri": "http://10.0.0.5:631/ipp/print"}), "ipp://10.0.0.5:631/ipp/print")
        self.assertEqual(t({"portKind": "ipp", "uri": "https://printer.lan/ipp/print"}), "ipps://printer.lan:443/ipp/print")
        self.assertEqual(t({"portKind": "ipp", "uri": "http://printer.lan/printers/x"}), "ipp://printer.lan:80/printers/x")
        self.assertEqual(t({"portKind": "ipp", "uri": "ipps://p:8631/ipp/print"}), "ipps://p:8631/ipp/print")
        self.assertEqual(t({"portKind": "tcpip"}), "")
        self.assertEqual(t({"portKind": "usb"}), "")


class Import(Fixture):
    def test_the_e2e_printers(self):
        r = self.run_import()
        office = r["Office Laser 5eed"]
        self.assertEqual(office["status"], "added")
        self.assertEqual(office["queue"], "Office_Laser_5eed")
        self.assertEqual(office["uri"], "ipp://127.0.0.2:631/ipp/print")
        self.assertTrue(office["default"])
        self.assertIn("lastTried", office)
        self.assertIn("-p Office_Laser_5eed -E -v ipp://127.0.0.2:631/ipp/print -m everywhere", self.calls())
        self.assertIn("-d Office_Laser_5eed", self.calls())
        self.assertEqual(r["Lab Printer 5eed"]["status"], "waiting")
        self.assertEqual(r["Lab Printer 5eed"]["uri"], "ipp://192.0.2.44:631/ipp/print")
        self.assertEqual(r["Label Printer 5eed"]["status"], "not-migrated")
        self.assertEqual(r["Label Printer 5eed"]["reason"],
                         "connected by cable to this PC: plug it in, and a driverless USB printer "
                         "is set up automatically; others need their Linux driver")
        self.assertEqual(r["Microsoft Print to PDF"]["status"], "not-migrated")
        self.assertEqual(r["Microsoft Print to PDF"]["reason"], "Windows-only virtual printer")
        self.assertEqual(self.log.splitlines(), [
            "wootc-printer-import: Office Laser 5eed: added ipp://127.0.0.2:631/ipp/print",
            "wootc-printer-import: Lab Printer 5eed: waiting: no answer from test",
            "wootc-printer-import: Label Printer 5eed: not migrated: connected by cable to this PC: "
            "plug it in, and a driverless USB printer is set up automatically; others need their Linux driver",
            "wootc-printer-import: Microsoft Print to PDF: not migrated: Windows-only virtual printer",
        ])
        self.assertEqual(oct(self.state.stat().st_mode & 0o777), "0o644")
        # No lpadmin for a printer that did not answer, or a non-network one.
        self.assertEqual(len([c for c in self.calls() if c.startswith("-p ")]), 1)

    def test_wsd_and_other_reasons(self):
        self.windows([{"name": "Brother", "portName": "WSD-1234", "portKind": "wsd"},
                      {"name": "Floor3", "portName": "\\\\print01\\Floor3", "portKind": "other"},
                      {"name": "OneNote", "portName": "nul:", "portKind": "file"}])
        r = self.run_import()
        self.assertEqual(r["Brother"]["reason"],
                         "found by Windows on the network (WSD); if it supports driverless printing, "
                         "Settings → Printers lists it")
        self.assertIn("\\\\print01\\Floor3", r["Floor3"]["reason"])
        self.assertEqual(r["OneNote"]["reason"], "Windows-only virtual printer")
        self.assertEqual(self.calls(), [])

    def test_waiting_is_retried_on_the_next_boot(self):
        self.reach = {}
        r = self.run_import()
        self.assertEqual(r["Office Laser 5eed"]["status"], "waiting")
        self.assertEqual(self.queues(), [])
        self.reach = {"127.0.0.2": True}
        r = self.run_import()
        self.assertEqual(r["Office Laser 5eed"]["status"], "added")
        self.assertEqual(self.queues(), ["Office_Laser_5eed ipp://127.0.0.2:631/ipp/print"])

    def test_lpadmin_failure_is_waiting_with_its_message(self):
        (self.cups / "fail").write_text("lpadmin: Unable to query printer: Connection refused")
        r = self.run_import()
        self.assertEqual(r["Office Laser 5eed"]["status"], "waiting")
        self.assertEqual(r["Office Laser 5eed"]["reason"], "lpadmin: Unable to query printer: Connection refused")
        self.assertNotIn("-d Office_Laser_5eed", self.calls())

    def test_rerun_is_idempotent(self):
        first = self.run_import()
        calls = self.calls()
        second = self.run_import()
        self.assertEqual(first["Office Laser 5eed"], second["Office Laser 5eed"])
        new = self.calls()[len(calls):]
        self.assertFalse([c for c in new if "Office_Laser_5eed" in c], new)

    def test_a_queue_the_user_removed_is_never_re_added(self):
        self.run_import()
        (self.cups / "queues").write_text("")          # lpadmin -x by the user
        r = self.run_import()
        self.assertEqual(r["Office Laser 5eed"]["status"], "added")
        self.assertEqual(self.queues(), [])

    def test_an_existing_queue_of_the_same_name_is_left_alone(self):
        (self.cups / "queues").write_text("office_laser_5eed ipp://elsewhere/ipp/print\n")
        r = self.run_import()
        self.assertEqual(r["Office Laser 5eed"]["status"], "not-migrated")
        self.assertIn("already set up", r["Office Laser 5eed"]["reason"])
        self.assertFalse([c for c in self.calls() if "Office_Laser_5eed" in c])

    def test_an_existing_linux_default_is_kept(self):
        (self.cups / "default").write_text("Mine")
        self.run_import()
        self.assertEqual((self.cups / "default").read_text(), "Mine")
        self.assertNotIn("-d Office_Laser_5eed", self.calls())

    def test_cups_down_is_waiting(self):
        (self.cups / "down").write_text("")
        r = self.run_import()
        self.assertEqual(r["Office Laser 5eed"]["status"], "waiting")
        self.assertEqual(r["Office Laser 5eed"]["reason"], "the print service (CUPS) is not running")
        self.assertEqual(self.calls(), [])

    def test_chooser_off_adds_nothing(self):
        (self.cups / "selection-rc").write_text("1")
        r = self.run_import()
        self.assertEqual(r["Office Laser 5eed"]["status"], "not-migrated")
        self.assertEqual(r["Office Laser 5eed"]["reason"], "switched off in Bring over from Windows")
        self.assertEqual(self.calls(), [])
        # Switched back on: the next boot sets it up.
        (self.cups / "selection-rc").unlink()
        self.assertEqual(self.run_import()["Office Laser 5eed"]["status"], "added")

    def test_chooser_item_off_skips_only_that_printer(self):
        self.windows(WINDOWS + [{"name": "Hall", "portKind": "tcpip", "host": "127.0.0.2"}])
        (self.cups / "selection-rc-Office Laser 5eed").write_text("1")
        r = self.run_import()
        self.assertEqual(r["Office Laser 5eed"]["status"], "not-migrated")
        self.assertEqual(r["Hall"]["status"], "added")

    def test_chooser_off_never_removes_what_was_added(self):
        self.run_import()
        (self.cups / "selection-rc").write_text("1")
        r = self.run_import()
        self.assertEqual(r["Office Laser 5eed"]["status"], "added")
        self.assertEqual(len(self.queues()), 1)

    def test_no_windows_list_is_a_quiet_no_op(self):
        Path(self.mod.SOURCE).unlink()
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(self.mod.migrate(), 0)
        self.assertFalse(self.state.exists())
        self.assertIn("nothing to do", out.getvalue())


class Report(Fixture):
    def report(self):
        env = {**os.environ, "WOOTC_HOST": str(self.host), "WOOTC_PRINTER_STATE": str(self.state)}
        out = subprocess.run([sys.executable, str(IMPORTER), "--report"], env=env,
                             capture_output=True, text=True, check=True).stdout
        return {r["name"]: r for r in json.loads(out)["printers"]}

    def test_report_before_the_first_run_is_the_plan(self):
        r = self.report()
        self.assertEqual(r["Office Laser 5eed"]["status"], "pending")
        self.assertEqual(r["Office Laser 5eed"]["uri"], "ipp://127.0.0.2:631/ipp/print")
        self.assertEqual(r["Microsoft Print to PDF"]["status"], "not-migrated")
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.state.exists())

    def test_report_after_a_run_is_the_state(self):
        self.run_import()
        r = self.report()
        self.assertEqual(r["Office Laser 5eed"]["status"], "added")
        self.assertEqual(r["Lab Printer 5eed"]["status"], "waiting")

    def test_manifest_lists_every_printer_with_its_status(self):
        self.run_import()
        env = {**os.environ, "WOOTC_HOST": str(self.host), "WOOTC_PRINTER_STATE": str(self.state)}
        (self.host / "Users" / "alice").mkdir(parents=True)
        out = subprocess.run([sys.executable, str(MANIFEST), "scan", "alice"], env=env,
                             capture_output=True, text=True, check=True).stdout
        cat = {c["id"]: c for c in json.loads(out)["users"][0]["categories"]}["printers"]
        self.assertTrue(cat["present"])
        self.assertTrue(cat["defaultOn"])
        self.assertEqual(cat["summary"], "1 set up, 1 waiting, 2 not migrated")
        items = {i["id"]: i["detail"] for i in cat["items"]}
        self.assertEqual(items["Office Laser 5eed"],
                         "Set up as Office_Laser_5eed (ipp://127.0.0.2:631/ipp/print) · your Windows default printer")
        self.assertTrue(items["Lab Printer 5eed"].startswith("Waiting: no answer from test"))
        self.assertEqual(items["Microsoft Print to PDF"], "Not migrated: Windows-only virtual printer")


class Selection(unittest.TestCase):
    def test_printers_is_a_chooser_category(self):
        with tempfile.TemporaryDirectory() as tmp:
            sel = Path(tmp) / "migration-selection.json"
            sel.write_text(json.dumps({"version": 1, "selection": {"Alex": {
                "printers": {"on": True, "items": {"Office Laser 5eed": False}}}}}))
            env = {**os.environ, "WOOTC_SELECTION": str(sel)}
            run = lambda *a: subprocess.run([sys.executable, str(SELECTION), "alex", *a], env=env).returncode
            self.assertEqual(run("printers"), 0)
            self.assertEqual(run("printers", "Office Laser 5eed"), 1)
            self.assertEqual(run("printers", "Lab Printer 5eed"), 0)
        usage = subprocess.run([sys.executable, str(SELECTION)], capture_output=True, text=True).stderr
        self.assertIn("printers", usage)


if __name__ == "__main__":
    unittest.main()
