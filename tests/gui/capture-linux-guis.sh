#!/usr/bin/env bash
# capture-linux-guis.sh — regenerate the Linux-side GUI screenshots for
# docs/gui-walkthrough.md. The Windows installer shots come from the Playwright
# suite; these are the GTK4/libadwaita apps that run on the migrated system.
#
# Everything happens inside one Fedora container (gtk4 + libadwaita + Xvfb), so
# it needs no desktop, no display and no GTK stack on the host — just podman.
# Each GUI is launched against fixture data (the same WOOTC_* hooks the unit
# tests use), so the screenshots show a realistic, reproducible state.
#
#   bash tests/gui/capture-linux-guis.sh        → writes docs/screenshots/*.png

set -Eeuo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT="$REPO_ROOT/docs/screenshots"
IMG="${WOOTC_GUI_SHOT_IMAGE:-registry.fedoraproject.org/fedora:41}"
mkdir -p "$OUT"

INNER=$(cat <<'INNER'
set -Eeuo pipefail
dnf install -y -q python3-gobject gtk4 libadwaita xorg-x11-server-Xvfb \
    ImageMagick util-linux dbus-daemon mesa-libGLES mesa-dri-drivers \
    google-noto-sans-fonts >/dev/null 2>&1

Xvfb :99 -screen 0 1100x820x24 >/dev/null 2>&1 &
# GSK_RENDERER=cairo: GTK4 defaults to a GPU (Vulkan/GL) renderer that cannot
# initialize in a container with no DRM device — it aborts with
# "Couldn't open libGLESv2.so.2". The cairo software renderer draws identical
# widgetry with no GPU at all, which is exactly what headless capture needs.
export DISPLAY=:99 GDK_BACKEND=x11 GTK_A11Y=none GSK_RENDERER=cairo
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
sleep 2

shot() {  # shot <name> <seconds-to-settle>
    sleep "${2:-4}"
    import -window root -quality 95 "/tmp/raw.png" 2>/dev/null && convert /tmp/raw.png -trim +repage "/out/$1.png" 2>/dev/null || \
        echo "  !! screenshot failed: $1"
    echo "  captured $1"
    pkill -f "wootc-.*-gui" 2>/dev/null || true; pkill -f dbus-run-session 2>/dev/null || true
    sleep 1
}

# ── fixtures: a believable Windows volume ───────────────────────────────────
H=/fixture/host
mkdir -p "$H/Users/Alex/"{Documents,Pictures,Downloads,Music,Videos,Desktop}
for f in tax-2025.pdf notes.md resume.docx; do echo x > "$H/Users/Alex/Documents/$f"; done
for f in trip.jpg cat.png; do echo x > "$H/Users/Alex/Pictures/$f"; done
echo x > "$H/Users/Alex/Downloads/installer.exe"
mkdir -p "$H/Users/Alex/AppData/Roaming/Mozilla/Firefox"
printf '[Install0]\n' > "$H/Users/Alex/AppData/Roaming/Mozilla/Firefox/profiles.ini"
mkdir -p "$H/Users/Alex/AppData/Local/Google/Chrome/User Data/Default"
echo '{}' > "$H/Users/Alex/AppData/Local/Google/Chrome/User Data/Default/Bookmarks"
mkdir -p "$H/Program Files (x86)/Steam/steamapps"
echo vdf > "$H/Program Files (x86)/Steam/steamapps/libraryfolders.vdf"
mkdir -p "$H/wootc/install/wifi"
for n in HomeWiFi Cafe Office; do echo '<x/>' > "$H/wootc/install/wifi/$n.xml"; done
mkdir -p "$H/Users/Alex/AppData/Local/lxss/rootfs"
mkdir -p "$H/Users/Alex/AppData/Roaming/Microsoft/UProof"
printf 'wootc\r\n' > "$H/Users/Alex/AppData/Roaming/Microsoft/UProof/CUSTOM.DIC"

# ── 1. Migration chooser (what should we bring over?) ───────────────────────
echo "capturing manifest GUI..."
WOOTC_MANIFEST_BIN=/scripts/wootc-manifest WOOTC_HOST="$H" \
    WOOTC_SELECTION=/tmp/sel.json \
    dbus-run-session -- python3 /scripts/wootc-manifest-gui >/tmp/g1.log 2>&1 &
shot 13-migration-chooser 6

# ── 1b. Set up your account (identity pre-filled, password is the only ask) ─
echo "capturing user setup GUI..."
cat > /tmp/identity.json <<'JSON'
{"winUser":"Alex","username":"alex","fullName":"Alex Morgan",
 "email":"alex@example.com","avatar":null,"locale":"en_GB",
 "keyboardLayout":null,"timezone":null,
 "password":{"migratable":false,
             "note":"Set a new password for Linux \u2014 Windows passwords can't be carried over."}}
JSON
printf '#!/bin/sh\ncat /tmp/identity.json\n' > /tmp/fake-identity
chmod +x /tmp/fake-identity
WOOTC_IDENTITY_BIN=/tmp/fake-identity WOOTC_ACCOUNT=/tmp/account.json \
    dbus-run-session -- python3 /scripts/wootc-user-gui >/tmp/g1b.log 2>&1 &
shot 13b-account-setup 6

# ── 2. Move fully to Linux (Phase 3) — still on the Windows-hosted disk ─────
echo "capturing go-native GUI (on loopback)..."
GNHOME=/fixture/gnhome; mkdir -p "$GNHOME/.config/wootc"
WOOTC_GN_BIN=/scripts/wootc-go-native WOOTC_GN_FORCE_LOOP=1 \
    WOOTC_GN_ROOT_SRC=/dev/nbd0p3 WOOTC_GN_HOSTCONF=/nonexistent \
    WOOTC_GN_HOME="$GNHOME" \
    dbus-run-session -- python3 /scripts/wootc-go-native-gui >/tmp/g2.log 2>&1 &
shot 14-move-to-linux 6

# ── 3. Move fully to Linux — already native, reclaim offered ────────────────
echo "capturing go-native GUI (native, reclaim available)..."
touch "$GNHOME/.config/wootc/converted-Documents" "$GNHOME/.config/wootc/converted-Pictures"
WOOTC_GN_BIN=/scripts/wootc-go-native WOOTC_GN_FORCE_LOOP=0 \
    WOOTC_GN_ROOT_SRC=/dev/sda3 WOOTC_GN_HOSTCONF=/nonexistent \
    WOOTC_GN_HOME="$GNHOME" \
    dbus-run-session -- python3 /scripts/wootc-go-native-gui >/tmp/g2.log 2>&1 &
shot 15-reclaim-windows 6

# ── 4. Bring your Windows over (external disk / BitLocker import) ───────────
echo "capturing import GUI..."
cat > /tmp/lsblk.json <<'JSON'
{"blockdevices":[
 {"path":"/dev/sda","type":"disk","fstype":null,"size":512110190592,"pkname":null,"children":[
   {"path":"/dev/sda1","type":"part","fstype":"ntfs","size":499999999999,"label":"Windows","pkname":"sda"}]},
 {"path":"/dev/sdb","type":"disk","fstype":null,"size":1000204886016,"pkname":null,"children":[
   {"path":"/dev/sdb1","type":"part","fstype":"ntfs","size":999999999999,"label":"Backup Drive","pkname":"sdb"}]},
 {"path":"/dev/sdc","type":"disk","fstype":null,"size":256060514304,"pkname":null,"children":[
   {"path":"/dev/sdc1","type":"part","fstype":"BitLocker","size":250000000000,"label":"Encrypted USB","pkname":"sdc"}]}
]}
JSON
WOOTC_IMPORT_BIN=/scripts/wootc-import WOOTC_IMPORT_LSBLK=/tmp/lsblk.json \
    WOOTC_IMPORT_ROOTDISK=sda \
    dbus-run-session -- python3 /scripts/wootc-import-gui >/tmp/g4.log 2>&1 &
shot 16-bring-windows-over 6

for l in /tmp/g1.log /tmp/g2.log /tmp/g4.log; do [ -s "$l" ] && { echo "--- $l ---"; tail -4 "$l"; }; done
echo "done"
INNER
)

echo "Capturing Linux GUI screenshots into $OUT ..."
podman run --rm \
    -v "$REPO_ROOT/payload/migration:/scripts:ro,Z" \
    -v "$OUT:/out:Z" \
    "$IMG" bash -c "$INNER"

echo
ls -lh "$OUT"/1[3-6]-*.png 2>/dev/null || echo "(no screenshots produced)"
