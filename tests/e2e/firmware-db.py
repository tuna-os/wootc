#!/usr/bin/env python3
"""firmware-db.py — the E2E firmware `db` axis (#322).

Under Secure Boot the firmware launches only a loader signed by a CA in its
`db` variable. Microsoft's third-party CA (the one that signs shim) exists in
two generations, 2011 and 2023, and real PCs hold either, both, or neither
(Secured-core PCs ship with the third-party CA turned off). Dockur's stock
OVMF vars hold both, so without this axis the harness only ever proves the
easiest machine.

A cell names the third-party CAs the firmware trusts:

    2011   Microsoft Corporation UEFI CA 2011 only
    2023   Microsoft UEFI CA 2023 only (+ the 2023 Option ROM CA, which
           Microsoft's rollout installs beside it)
    both   both generations
    none   neither: Windows boots, no shim can

Every cell keeps Windows' own CAs (Production PCA 2011, Windows UEFI CA 2023):
the VM has to boot Windows for the installer to run at all.

    firmware-db.py build --cell 2023 VARS     rewrite db in an OVMF vars file
    firmware-db.py grade --cell 2023 < B64    grade a db the GUEST read back
                                              (base64 of Get-SecureBootUEFI)

`build` is setup. `grade` is the assertion: it reads what Windows itself sees,
so a vars file dockur ignored, or a path it never mounted, fails the cell
instead of passing it on the stock db.

`build` needs the virt-fw-vars command (pip install virt-firmware), which
edits edk2 varstores; it is run as a command, so it may live in its own venv.
The Microsoft certificates are Microsoft's published CA certificates, kept in
firmware-certs/ (copied from virt-firmware 26.9). `grade` needs only openssl(1).
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

MICROSOFT_OWNER = "77fa9abd-0359-4d32-bd60-28f4e78f784b"

CERTS = Path(__file__).resolve().parent / "firmware-certs"
WINDOWS_CERTS = ("windows-2011.pem", "windows-2023.pem")
CELL_CERTS = {
    "2011": ("ms-uefi-2011.pem",),
    "2023": ("ms-uefi-2023.pem", "ms-uefi-rom-2023.pem"),
    "both": ("ms-uefi-2011.pem", "ms-uefi-2023.pem", "ms-uefi-rom-2023.pem"),
    "none": (),
}
EXPECTED = {"2011": ["2011"], "2023": ["2023"], "both": ["2011", "2023"], "none": []}

# The same issuer patterns the installer (app/secureboot.go) and the release
# grader (packaging/shim-authorities.py) use. Kept separate on purpose: this
# grades the firmware, and a shared bug would grade itself green.
THIRD_PARTY = (
    (re.compile(r"Microsoft Corporation UEFI CA 2011"), "2011"),
    (re.compile(r"Microsoft (?:Corporation )?UEFI CA 2023"), "2023"),
)
WINDOWS = (
    re.compile(r"Microsoft Windows Production PCA 2011"),
    re.compile(r"Windows UEFI CA 2023"),
)

EFI_CERT_X509 = bytes.fromhex("a159c0a5e494a74a87b5ab155c2bf072")


def subject(der: bytes) -> str:
    """One certificate's subject line, via openssl(1) like the release's
    shim grader: no third-party Python modules on the grading path."""
    out = subprocess.run(["openssl", "x509", "-inform", "DER", "-noout", "-subject"],
                         input=der, capture_output=True, check=False)
    if out.returncode != 0:
        raise ValueError("unparseable X.509 certificate in db")
    return out.stdout.decode("utf-8", "replace").strip()


def db_subjects(db: bytes) -> list[str]:
    """Subjects of every X.509 certificate in an EFI_SIGNATURE_LIST chain."""
    out = []
    off = 0
    while off + 28 <= len(db):
        sig_type = db[off:off + 16]
        list_size, header_size, sig_size = struct.unpack_from("<III", db, off + 16)
        if list_size < 28 or sig_size <= 16 or off + list_size > len(db):
            raise ValueError(f"corrupt signature list at offset {off}")
        if sig_type == EFI_CERT_X509:
            entry = off + 28 + header_size
            while entry + sig_size <= off + list_size:
                out.append(subject(db[entry + 16:entry + sig_size]))
                entry += sig_size
        off += list_size
    return out


def grade(cell: str, db: bytes) -> list[str]:
    """Return the problems with db for this cell; empty means it matches."""
    subjects = db_subjects(db)
    if not subjects:
        return ["db holds no X.509 certificates"]
    problems = []
    gens = sorted({gen for s in subjects for rx, gen in THIRD_PARTY if rx.search(s)})
    if gens != EXPECTED[cell]:
        problems.append(f"third-party CAs {gens or 'none'}, cell '{cell}' wants {EXPECTED[cell] or 'none'}")
    for rx in WINDOWS:
        if not any(rx.search(s) for s in subjects):
            problems.append(f"Windows CA missing ({rx.pattern}): Windows itself could not boot")
    return problems


def build(cell: str, vars_path: Path) -> None:
    """Replace db in an edk2 vars file. Every other variable is kept, so a
    vars file Windows already booted from keeps its boot entries."""
    cmd = ["virt-fw-vars", "--loglevel", "warning", "--inplace", str(vars_path), "--delete", "db"]
    for name in WINDOWS_CERTS + CELL_CERTS[cell]:
        cmd += ["--add-db", MICROSOFT_OWNER, str(CERTS / name)]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)

    # Read the result back and grade it with the same rules the guest check
    # uses, so a tool that silently skipped a certificate fails here, on the
    # host, before an hour of VM time.
    with tempfile.TemporaryDirectory() as tmp:
        dump = Path(tmp) / "vars.json"
        subprocess.run(["virt-fw-vars", "--loglevel", "warning", "-i", str(vars_path),
                        "--output-json", str(dump)], check=True, stdout=subprocess.DEVNULL)
        variables = json.loads(dump.read_text())["variables"]
    db = [v for v in variables if v.get("name") == "db"]
    if len(db) != 1:
        raise SystemExit(f"built vars hold {len(db)} db variables, want 1")
    problems = grade(cell, bytes.fromhex(db[0]["data"]))
    if problems:
        raise SystemExit("built db does not match cell: " + "; ".join(problems))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("op", choices=["build", "grade"])
    ap.add_argument("--cell", required=True, choices=sorted(CELL_CERTS))
    ap.add_argument("vars", nargs="?", help="OVMF vars file (build)")
    args = ap.parse_intermixed_args()

    if args.op == "build":
        if not args.vars:
            ap.error("build needs a vars file")
        build(args.cell, Path(args.vars))
        print(f"db rewritten for cell {args.cell}: {args.vars}")
        return 0

    raw = sys.stdin.read().strip()
    try:
        db = base64.b64decode(raw, validate=True)
        problems = grade(args.cell, db)
    except ValueError as exc:
        problems = [f"unreadable db: {exc}"]
    if problems:
        print("; ".join(problems))
        return 1
    print(f"db matches cell {args.cell}: third-party CAs {EXPECTED[args.cell] or 'none'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
