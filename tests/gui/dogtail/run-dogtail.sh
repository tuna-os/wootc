#!/usr/bin/env bash
# run-dogtail.sh — containerized runner for the dogtail AT-SPI GUI suite.
#
# Spins up one Fedora container with GTK4 + libadwaita + dogtail + Xvfb +
# an a11y bus, builds the same believable Windows-volume fixture the
# screenshot capture uses, and executes dogtail-suite.py against the REAL
# wootc GTK apps. Needs only podman — no desktop, no display on the host.
#
# The suite itself is guest-portable: run it inside a booted Phase-2/native
# image to test the real deployment (it exits 77 SKIP on images that do not
# ship dogtail — most don't; that is expected, not a failure).
#
#   bash tests/gui/dogtail/run-dogtail.sh

set -Eeuo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
IMG="${WOOTC_GUI_TEST_IMAGE:-registry.fedoraproject.org/fedora:41}"

INNER=$(cat <<'INNER'
set -Eeuo pipefail
dnf install -y -q python3-dogtail python3-gobject gtk4 libadwaita \
    xorg-x11-server-Xvfb at-spi2-core dbus-daemon mesa-libGLES \
    mesa-dri-drivers google-noto-sans-fonts util-linux \
    gsettings-desktop-schemas dconf >/dev/null 2>&1

Xvfb :99 -screen 0 1100x820x24 >/dev/null 2>&1 &
export DISPLAY=:99 GDK_BACKEND=x11 GSK_RENDERER=cairo
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
sleep 2

# ── fixture: a believable Windows volume (same shape as the captures) ──────
H=/fixture/host
mkdir -p "$H/Users/Alex/"{Documents,Pictures,Downloads,Music,Videos,Desktop}
for f in tax-2025.pdf notes.md resume.docx; do echo x > "$H/Users/Alex/Documents/$f"; done
for f in trip.jpg cat.png; do echo x > "$H/Users/Alex/Pictures/$f"; done
echo x > "$H/Users/Alex/Downloads/installer.exe"
mkdir -p "$H/Users/Alex/AppData/Roaming/Mozilla/Firefox"
printf '[Install0]\n' > "$H/Users/Alex/AppData/Roaming/Mozilla/Firefox/profiles.ini"

# dogtail talks to the session a11y bus; GTK4 connects to it automatically
# when org.a11y.Bus is activatable (at-spi2-core provides the service files).
# dogtail additionally gates on the toolkit-accessibility GSetting, which
# must be flipped inside the same dbus session it will read it from.
exec dbus-run-session -- bash -c \
    'gsettings set org.gnome.desktop.interface toolkit-accessibility true 2>/dev/null || true; \
     exec python3 /suite/dogtail-suite.py'
INNER
)

podman run --rm \
    -v "$REPO_ROOT/payload/migration:/scripts:ro" \
    -v "$REPO_ROOT/tests/gui/dogtail:/suite:ro" \
    -e WOOTC_GUI_DIR=/scripts \
    -e WOOTC_HOST=/fixture/host \
    "$IMG" bash -c "$INNER"
