#!/usr/bin/env python3
"""Take a QEMU screendump via monitor socket and save as PNG."""
import socket, struct, zlib, time, sys

CTR = sys.argv[1] if len(sys.argv) > 1 else "wootc-e2e-windows"
MONITOR = "/run/shm/monitor.sock"
OUT = "/tmp/wootc-screen.png"

# Grab screendump from inside the container
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(MONITOR)
time.sleep(0.3)
s.settimeout(0.5)
try:
    s.recv(4096)
except:
    pass
s.settimeout(None)
s.send(b"screendump /tmp/snap.ppm\n")
time.sleep(2)
s.close()

# Read PPM, convert to PNG
with open("/tmp/snap.ppm", "rb") as f:
    raw_ppm = f.read()
lines = raw_ppm.split(b"\n")
w, h = map(int, lines[1].split())
header_len = sum(len(lines[i]) + 1 for i in range(3))
pixels = raw_ppm[header_len:]


def chunk(name, data):
    return (
        struct.pack(">I", len(data))
        + name
        + data
        + struct.pack(">I", zlib.crc32(name + data) & 0xFFFFFFFF)
    )


raw = b"".join(b"\x00" + pixels[y * w * 3 : (y + 1) * w * 3] for y in range(h))
with open(OUT, "wb") as f:
    f.write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
print(f"Saved: {OUT}")
