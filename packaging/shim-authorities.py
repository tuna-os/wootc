#!/usr/bin/env python3
"""shim-authorities.py — which Microsoft UEFI CA signed this EFI binary?

A machine's firmware trusts a set of certificate authorities (the UEFI `db`
variable). Microsoft's third-party signing authority exists in two
generations: "Microsoft Corporation UEFI CA 2011", whose certificate expired
2026-06-27, and "Microsoft UEFI CA 2023", which signs everything issued now.
Firmware does not check expiry, so a machine holding the 2011 CA still boots a
2011-signed shim — but new machines increasingly ship the 2023 CA alone, and
on those a 2011-only shim dies with "bad shim signature" after the reboot,
with nothing said beforehand (#322).

So the build has to know what it is staging. This reads the Authenticode
signatures out of a PE image's security directory and reports which Microsoft
CA generations signed it. A dual-signed shim carries two WIN_CERTIFICATE
entries; both are walked.

    shim-authorities.py shimx64.efi            -> 2011,2023
    shim-authorities.py --json shimx64.efi ... -> {"shimx64.efi": ["2011","2023"]}
    shim-authorities.py --require 2023 shim…   -> exit 1 unless 2023 signed

No third-party modules: openssl(1) does the PKCS#7 parsing.
"""

from __future__ import annotations

import argparse
import json
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

# Issuer common names, mapped to the generation names the installer and the
# firmware preflight speak. Matched on the issuer, not the leaf: the leaf is
# a per-publisher certificate ("Microsoft Windows UEFI Driver Publisher"),
# and it is the CA above it that has to be in the firmware's db.
CA_PATTERNS = (
    (re.compile(r"Microsoft Corporation UEFI CA 2011"), "2011"),
    (re.compile(r"Microsoft (?:Corporation )?UEFI CA 2023"), "2023"),
)


class PEError(RuntimeError):
    pass


def _u16(data: bytes, off: int) -> int:
    if off < 0 or off + 2 > len(data):
        raise PEError("PE field runs past the end of the image")
    return struct.unpack_from("<H", data, off)[0]


def _u32(data: bytes, off: int) -> int:
    if off < 0 or off + 4 > len(data):
        raise PEError("PE field runs past the end of the image")
    return struct.unpack_from("<I", data, off)[0]


def security_directory(data: bytes) -> tuple[int, int]:
    """Return (offset, size) of the certificate table, or (0, 0) if unsigned."""
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise PEError("not a PE image (no MZ header)")
    pe = _u32(data, 0x3C)
    if pe + 24 > len(data) or data[pe : pe + 4] != b"PE\0\0":
        raise PEError("not a PE image (no PE signature)")
    opt_size = _u16(data, pe + 20)
    opt = pe + 24
    if opt_size == 0 or opt + opt_size > len(data):
        raise PEError("PE optional header runs past the end of the image")
    magic = _u16(data, opt)
    # The data-directory array starts after the optional header's fixed part:
    # 112 bytes for PE32+ (magic 0x20b), 96 for PE32 (0x10b).
    if magic == 0x20B:
        dirs = opt + 112
    elif magic == 0x10B:
        dirs = opt + 96
    else:
        raise PEError(f"unknown PE optional header magic {magic:#x}")
    # Index 4 is IMAGE_DIRECTORY_ENTRY_SECURITY; each entry is (RVA, size),
    # and for this one the "RVA" is really a file offset.
    entry = dirs + 4 * 8
    return _u32(data, entry), _u32(data, entry + 4)


def pkcs7_blobs(data: bytes) -> list[bytes]:
    """Every WIN_CERTIFICATE payload in the image, in file order.

    A dual-signed binary appends a second WIN_CERTIFICATE after the first,
    each 8-byte aligned. Returning both is the whole point here: reporting
    only the first would call Fedora's dual-signed shim 2011-only.
    """
    off, size = security_directory(data)
    if off == 0 or size == 0:
        return []
    if off + size > len(data):
        raise PEError("certificate table runs past the end of the image")
    blob = data[off : off + size]
    out: list[bytes] = []
    pos = 0
    while pos + 8 <= len(blob):
        length = struct.unpack_from("<I", blob, pos)[0]
        if length < 8 or pos + length > len(blob):
            break
        out.append(blob[pos + 8 : pos + length])
        pos += (length + 7) & ~7
    return out


def issuers(pkcs7: bytes) -> list[str]:
    with tempfile.NamedTemporaryFile(suffix=".p7", delete=True) as tmp:
        tmp.write(pkcs7)
        tmp.flush()
        proc = subprocess.run(
            ["openssl", "pkcs7", "-inform", "DER", "-in", tmp.name,
             "-print_certs", "-noout", "-text"],
            capture_output=True, text=True, check=False,
        )
    if proc.returncode != 0:
        return []
    return re.findall(r"Issuer:.*", proc.stdout)


def authorities(path: Path) -> list[str]:
    """Microsoft CA generations that signed this image, sorted."""
    data = path.read_bytes()
    found: set[str] = set()
    for blob in pkcs7_blobs(data):
        for line in issuers(blob):
            for pattern, generation in CA_PATTERNS:
                if pattern.search(line):
                    found.add(generation)
    return sorted(found)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("images", nargs="+", type=Path)
    ap.add_argument("--json", action="store_true",
                    help="emit {basename: [generations]} instead of a comma list")
    ap.add_argument("--require", metavar="GEN", action="append", default=[],
                    help="exit non-zero unless every image carries this generation")
    args = ap.parse_args(argv)

    result: dict[str, list[str]] = {}
    for image in args.images:
        try:
            result[image.name] = authorities(image)
        except PEError as exc:
            print(f"{image}: {exc}", file=sys.stderr)
            return 2

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        for name, gens in sorted(result.items()):
            print(f"{name}\t{','.join(gens) if gens else 'none'}")

    rc = 0
    for want in args.require:
        for name, gens in sorted(result.items()):
            if want not in gens:
                print(f"::error::{name} is not signed by the Microsoft UEFI CA {want} "
                      f"(found: {','.join(gens) if gens else 'no Microsoft UEFI CA'}). "
                      f"Machines whose firmware trusts only the {want} authority would "
                      f"fail with 'bad shim signature' after the reboot (#322).",
                      file=sys.stderr)
                rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
