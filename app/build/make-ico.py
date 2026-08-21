#!/usr/bin/env python3
"""Pack appicon.png into a multi-resolution windows/icon.ico.

A real file rather than a `python3 -c` one-liner inside the justfile: the
recipe body is dedented by just, then re-parsed by bash, then again by python,
and threading quotes through all three is how the PowerShell payloads in this
repo grew their bugs.

Windows picks the closest entry for each context (16px tray/taskbar, 32px
title bar and Alt-Tab, 256px Explorer "extra large"), so all of them ship. The
source MUST be the largest image — PIL derives the smaller entries by
downscaling it, and handing it a 16px base silently produces a 16px-only .ico.
"""

from PIL import Image

SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]

src = Image.open("appicon.png").convert("RGBA")
if src.size != (256, 256):
    raise SystemExit(f"appicon.png must be 256x256, got {src.size}")

src.save("windows/icon.ico", format="ICO", sizes=SIZES)

written = sorted(Image.open("windows/icon.ico").info.get("sizes", []))
if written != sorted(SIZES):
    raise SystemExit(f"icon.ico has {written}, expected {sorted(SIZES)}")
print("windows/icon.ico:", written)
