#!/usr/bin/env bash
# test-bridge.sh — User Data Bridge unit/integration tests in a container.
# Proves data actually migrates: bind-mounts, Steam registration, browser
# import, stage-4 conversion (+ its reversibility guarantees), the
# converted-marker contract, look mapping (dry-run), and the ESP-sync
# logic against fake /boot + ESP trees. Needs no VM, no desktop, no root
# on the host — everything runs inside one privileged Fedora container.
#
# Usage: bash tests/migration/test-bridge.sh   (host with podman)

set -Eeuo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
IMG="${WOOTC_TEST_IMAGE:-registry.fedoraproject.org/fedora:41}"

INNER=$(cat <<'INNER'
set -Eeuo pipefail
PASS=0; FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
check(){ if eval "$1"; then ok "$2"; else bad "$2"; fi; }

dnf install -y -q rsync python3 util-linux >/dev/null 2>&1 || true
# Put the migration scripts on PATH so their inter-script `command -v`
# calls resolve (mount-user-dirs invokes steam-bridge and detect-apps).
install -m755 /scripts/wootc-* /usr/local/bin/ 2>/dev/null || \
    { cp /scripts/wootc-* /usr/local/bin/ && chmod +x /usr/local/bin/wootc-*; }

# ── Fixtures: fake Windows volume at /run/wootc/host + Linux user ────────────────────
useradd -m -u 1000 alice
H=/home/alice
mkdir -p /run/wootc/host/Users/alice/{Documents,Pictures,Downloads,Music,Videos,Desktop}
echo "tax-return" > /run/wootc/host/Users/alice/Documents/taxes.txt
echo "cat"        > /run/wootc/host/Users/alice/Pictures/cat.jpg
mkdir -p /run/wootc/host/Users/Public/Documents   # must be ignored

# Steam: default library + extra library on C:
mkdir -p "/run/wootc/host/Program Files (x86)/Steam/steamapps/common/HL3"
cat > "/run/wootc/host/Program Files (x86)/Steam/steamapps/libraryfolders.vdf" <<'VDF'
"libraryfolders"
{
	"0"
	{
		"path"		"C:\\Program Files (x86)\\Steam"
	}
	"1"
	{
		"path"		"C:\\Games\\SteamLibrary"
	}
}
VDF
mkdir -p "/run/wootc/host/Games/SteamLibrary/steamapps/common/Portal9"
# Linux Steam already initialized (native path):
mkdir -p "$H/.local/share/Steam/steamapps"
printf '"libraryfolders"\n{\n}\n' > "$H/.local/share/Steam/steamapps/libraryfolders.vdf"

# Browsers: Firefox profile + Chrome bookmarks
FFW=/run/wootc/host/Users/alice/AppData/Roaming/Mozilla/Firefox
mkdir -p "$FFW/Profiles/abc.default-release"
printf '[Install0]\nDefault=Profiles/abc.default-release\n[Profile0]\nName=default\nIsRelative=1\nPath=Profiles/abc.default-release\n' > "$FFW/profiles.ini"
echo "places-db" > "$FFW/Profiles/abc.default-release/places.sqlite"
echo "logins"    > "$FFW/Profiles/abc.default-release/logins.json"
mkdir -p "$H/.mozilla/firefox"
CHW="/run/wootc/host/Users/alice/AppData/Local/Google/Chrome/User Data/Default"
mkdir -p "$CHW"
echo '{"roots":{}}' > "$CHW/Bookmarks"
mkdir -p "$H/.config/google-chrome/Default"

# Mock mountpoint /run/wootc/host as a real mountpoint for the script's guard.
mount --bind /run/wootc/host /run/wootc/host

# ── 1. Passthrough binds ────────────────────────────────────────────────────
bash /scripts/wootc-mount-user-dirs >/dev/null 2>&1 || true
check 'mountpoint -q /home/alice/Documents' "Documents bind-mounted into \$HOME"
check '[ "$(cat /home/alice/Documents/taxes.txt)" = tax-return ]' "bridged file readable with correct content"
check 'echo linux-note > /home/alice/Documents/from-linux.txt && [ -f /run/wootc/host/Users/alice/Documents/from-linux.txt ]' "write through bridge lands on Windows side"
check '! mountpoint -q /home/Public 2>/dev/null' "Public profile ignored"

# ── 2. Steam bridge ─────────────────────────────────────────────────────────
check '[ -f /home/alice/.config/wootc/bridge-steam.json ]' "steam bridge state recorded"
check 'grep -q "Program Files" /home/alice/.config/wootc/bridge-steam.json' "default Windows library detected"
check 'grep -q "Games/SteamLibrary" /home/alice/.config/wootc/bridge-steam.json' "extra C: library from libraryfolders.vdf detected"
check 'grep -q "Program Files" /home/alice/.local/share/Steam/steamapps/libraryfolders.vdf' "Windows library registered with Linux Steam"

# ── 3. Browser import ───────────────────────────────────────────────────────
bash /scripts/wootc-import-browser alice >/dev/null 2>&1 || true
check '[ -f /home/alice/.mozilla/firefox/windows-import.wootc/places.sqlite ]' "Firefox profile copied (history db present)"
check '[ -f /home/alice/.mozilla/firefox/windows-import.wootc/logins.json ]' "Firefox logins came with the profile"
check 'grep -q windows-import.wootc /home/alice/.mozilla/firefox/profiles.ini' "imported profile registered in profiles.ini"
check '[ -f "/home/alice/.config/google-chrome/Default/Bookmarks" ]' "Chrome bookmarks imported"
check '[ -f /home/alice/.config/wootc/bridge-browser.json ]' "browser import state recorded"

# ── 4. Stage-4 conversion + reversibility contract ─────────────────────────
bash /scripts/wootc-convert-dir alice Documents >/dev/null 2>&1 || true
check '! mountpoint -q /home/alice/Documents' "Documents no longer a bind after conversion"
check '[ "$(cat /home/alice/Documents/taxes.txt)" = tax-return ]' "converted copy has the data"
check '[ -f /run/wootc/host/Users/alice/Documents/taxes.txt ]' "Windows original untouched (reversibility)"
check '[ -e /home/alice/.config/wootc/converted-Documents ]' "conversion marker written"
# Re-running the passthrough must respect the marker:
bash /scripts/wootc-mount-user-dirs >/dev/null 2>&1 || true
check '! mountpoint -q /home/alice/Documents' "converted folder NOT re-bridged on next boot"
check 'mountpoint -q /home/alice/Pictures' "unconverted folders still bridged"

# ── 5. Look mapping (dry-run database) ─────────────────────────────────────
mkdir -p /tmp/slurp
printf '{"wallpaper":"wallpaper.jpg","darkMode":"true","accentColor":"#E62D42"}\n' > /tmp/slurp/slurp.json
touch /tmp/slurp/wallpaper.jpg
G=$(WOOTC_DRYRUN=1 WOOTC_SLURP_DIR=/tmp/slurp WOOTC_LOOK_MARKER=/tmp/mark-g \
    XDG_CURRENT_DESKTOP=GNOME HOME=/home/alice bash /scripts/wootc-apply-look)
check 'echo "$G" | grep -q "picture-uri.*wallpaper.jpg"' "GNOME: wallpaper command mapped"
check 'echo "$G" | grep -q "prefer-dark"' "GNOME: dark mode mapped"
check 'echo "$G" | grep -q "accent-color red"' "GNOME: #E62D42 mapped to nearest accent (red)"
K=$(WOOTC_DRYRUN=1 WOOTC_SLURP_DIR=/tmp/slurp WOOTC_LOOK_MARKER=/tmp/mark-k \
    XDG_CURRENT_DESKTOP=KDE HOME=/home/alice bash /scripts/wootc-apply-look)
check 'echo "$K" | grep -q plasma-apply-wallpaperimage' "KDE: wallpaper command mapped"
check 'echo "$K" | grep -q BreezeDark' "KDE: dark mode mapped"
check '[ -f /tmp/mark-g ] && grep -q "applied=gnome" /tmp/mark-g' "once-only marker written with DE"

# ── 5b. MS Office → LibreOffice bridge ──────────────────────────────────────
dnf install -y -q fontconfig >/dev/null 2>&1 || true
mkdir -p "/run/wootc/host/Users/alice/AppData/Roaming/Microsoft/UProof"
printf 'Kubernetes\r\nwootc\r\n' > "/run/wootc/host/Users/alice/AppData/Roaming/Microsoft/UProof/CUSTOM.DIC"
mkdir -p "/run/wootc/host/Users/alice/AppData/Roaming/Microsoft/Templates"
echo fake-template > "/run/wootc/host/Users/alice/AppData/Roaming/Microsoft/Templates/Report.dotx"
mkdir -p "/run/wootc/host/Users/alice/AppData/Local/Microsoft/Windows/Fonts"
echo fake-font > "/run/wootc/host/Users/alice/AppData/Local/Microsoft/Windows/Fonts/Calibri.ttf"
bash /scripts/wootc-office-bridge alice >/dev/null 2>&1 || true
LOU=/home/alice/.config/libreoffice/4/user
check "grep -q Kubernetes $LOU/wordbook/standard.dic" "Office: custom dictionary word migrated to LibreOffice"
check "[ -f '$LOU/template/Report.dotx' ]" "Office: template copied to LibreOffice"
check "[ -f /home/alice/.local/share/fonts/Calibri.ttf ]" "Office: Calibri font copied so documents render right"
check "grep -q 'MS Word 2007 XML' $LOU/registrymodifications.xcu" "Office: LibreOffice set to save as .docx by default"
check "[ -f /home/alice/.config/wootc/bridge-office.json ]" "Office: bridge state recorded"

# ── 6. ESP sync (BLS and classic layouts, fake ESP) ────────────────────────
mkdir -p /tmp/esp/EFI/wootc /tmp/esp/EFI/fedora /tmp/boot/loader/entries /tmp/boot/ostree/x
echo old-kernel > /tmp/esp/EFI/wootc/phase2-vmlinuz
echo old-initrd > /tmp/esp/EFI/wootc/phase2-initramfs.img
echo new-kernel > /tmp/boot/ostree/x/vmlinuz-6.1
echo new-initrd > /tmp/boot/ostree/x/initramfs-6.1.img
cat > /tmp/boot/loader/entries/ostree-2.conf <<'BLS'
title wootc
version 2
linux /ostree/x/vmlinuz-6.1
initrd /ostree/x/initramfs-6.1.img
options root=UUID=abcd rw ostree=/ostree/boot.1 wootc.host_uuid=FFFF loop=/wootc/disks/root.vhdx
BLS
echo "root=UUID=abcd wootc.host_uuid=FFFF loop=/wootc/disks/root.vhdx" > /tmp/cmdline
WOOTC_ESP_DIR=/tmp/esp WOOTC_BOOT_DIR=/tmp/boot WOOTC_CMDLINE=/tmp/cmdline \
    bash /scripts/wootc-esp-sync >/dev/null 2>&1 || true
check '[ "$(cat /tmp/esp/EFI/wootc/phase2-vmlinuz)" = new-kernel ]' "ESP sync: stale kernel refreshed from BLS entry"
check 'grep -q "loop=/wootc/disks/root.vhdx" /tmp/esp/EFI/fedora/grub.cfg' "ESP sync: grub.cfg carries loop-attach args"
# systemd-boot layout writes a BLS entry instead of touching GRUB.
mkdir -p /tmp/esp/EFI/systemd
echo efi > /tmp/esp/EFI/systemd/systemd-bootx64.efi
WOOTC_ESP_DIR=/tmp/esp WOOTC_BOOT_DIR=/tmp/boot WOOTC_CMDLINE=/tmp/cmdline \
    bash /scripts/wootc-esp-sync >/dev/null 2>&1 || true
check 'grep -q "loop=/wootc/disks/root.vhdx" /tmp/esp/loader/entries/wootc.conf' "ESP sync: systemd-boot BLS entry carries loop-attach args"
# Classic layout:
rm -rf /tmp/boot; mkdir -p /tmp/boot
echo classic-kernel > /tmp/boot/vmlinuz-6.2-generic
echo classic-initrd > /tmp/boot/initrd.img-6.2-generic
WOOTC_ESP_DIR=/tmp/esp WOOTC_BOOT_DIR=/tmp/boot WOOTC_CMDLINE=/tmp/cmdline \
    bash /scripts/wootc-esp-sync >/dev/null 2>&1 || true
check '[ "$(cat /tmp/esp/EFI/wootc/phase2-vmlinuz)" = classic-kernel ]' "ESP sync: classic /boot layout (Debian/Arch) handled"

# ── 7. WSL bridge (dotfiles + dpkg→Brewfile, secrets stay behind) ───────────
WSLR=/tmp/wslrootfs
mkdir -p "$WSLR/home/dev" "$WSLR/var/lib/dpkg"
printf 'export EDITOR=nvim\n'   > "$WSLR/home/dev/.bashrc"
printf '[user]\n\tname=Dev\n'   > "$WSLR/home/dev/.gitconfig"
mkdir -p "$WSLR/home/dev/.ssh"
echo 'ssh-ed25519 AAAA pub'      > "$WSLR/home/dev/.ssh/id_ed25519.pub"
echo 'PRIVATE-KEY-MUST-NOT-MOVE' > "$WSLR/home/dev/.ssh/id_ed25519"
cat > "$WSLR/var/lib/dpkg/status" <<'DPKG'
Package: ripgrep
Status: install ok installed

Package: golang-go
Status: install ok installed

Package: libssl3
Status: install ok installed

Package: neovim
Status: deinstall ok config-files
DPKG
WOOTC_WSL_ROOTFS="$WSLR" bash /scripts/wootc-wsl-bridge alice >/dev/null 2>&1 || true
BF=/home/alice/.config/wootc/Brewfile
# .gitconfig isn't in /etc/skel, so it proves a fresh copy; .bashrc IS in skel,
# so the bridge must leave alice's existing native one alone (non-clobber).
check '[ -f /home/alice/.gitconfig ] && grep -q "name=Dev" /home/alice/.gitconfig' "WSL: dotfiles copied into native home"
check '! grep -q EDITOR=nvim /home/alice/.bashrc' "WSL: existing native .bashrc not clobbered"
check '[ -f /home/alice/.ssh/id_ed25519.pub ]' "WSL: public key copied"
check '[ ! -f /home/alice/.ssh/id_ed25519 ]' "WSL: PRIVATE key left behind (never migrate secrets)"
check "grep -q '\"ripgrep\"' $BF" "WSL: installed dpkg pkg mapped to brew formula"
check "grep -q '\"go\"' $BF" "WSL: golang-go mapped to go"
check "! grep -q libssl3 $BF" "WSL: transitive library not mapped"
check "! grep -q neovim $BF" "WSL: deinstalled (config-files) pkg not mapped"
check "[ -f /home/alice/.config/wootc/wsl-bridge.json ]" "WSL: bridge state recorded"

# ── 8. go-native (Phase 3) — analysis is safe anywhere, gates hold ──────────
GN=/scripts/wootc-go-native
# plan/check run read-only; force the loopback state via the test hook.
PL=$(WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_HOSTCONF=/nonexistent WOOTC_GN_HOME=/home/alice bash "$GN" plan 2>&1 || true)
check 'echo "$PL" | grep -q "Graduate root to native"' "go-native: plan describes stage 5 graduate"
check 'echo "$PL" | grep -q "Remove Windows"' "go-native: plan describes stage 6 reclaim"
# Critical gate: reclaim must refuse while still on the loopback root.disk.
RC=$(WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK=/dev/loopX WOOTC_GN_NTFS=/dev/loopXp2 \
     bash "$GN" migrate --reclaim --execute 2>&1; echo "rc=$?")
check 'echo "$RC" | grep -q "still running from root.disk"' "go-native: --reclaim refuses on loopback"
check 'echo "$RC" | grep -q "rc=1"' "go-native: --reclaim exits non-zero on loopback"
# Phase-3 GUI engine (headless self-test): status parse + gates via the CLI.
GUI=$(WOOTC_GN_BIN=/scripts/wootc-go-native WOOTC_GN_FORCE_LOOP=1 \
      WOOTC_GN_HOSTCONF=/nonexistent WOOTC_GN_HOME=/home/alice \
      python3 /scripts/wootc-go-native-gui --self-test 2>&1; echo "rc=$?")
check 'echo "$GUI" | grep -q "self-test OK"' "go-native GUI: engine self-test passes"
check 'echo "$GUI" | grep -q "canGraduate=True"' "go-native GUI: surfaces canGraduate on loopback"

# ── 9. Migration manifest (discover → default-on catalog) ───────────────────
# /run/wootc/host already has Users/alice/{Documents,Pictures} + Steam libs from step 1-2.
MANI=$(WOOTC_HOST=/run/wootc/host python3 /scripts/wootc-manifest scan alice 2>&1)
check 'echo "$MANI" | python3 -c "import sys,json; d=json.load(sys.stdin); c={x[\"id\"]:x for x in d[\"users\"][0][\"categories\"]}; sys.exit(0 if c[\"files\"][\"present\"] and c[\"files\"][\"defaultOn\"] else 1)"' "manifest: files discovered + default-on"
check 'echo "$MANI" | python3 -c "import sys,json; d=json.load(sys.stdin); c={x[\"id\"]:x for x in d[\"users\"][0][\"categories\"]}; sys.exit(0 if c[\"games\"][\"present\"] else 1)"' "manifest: Steam games discovered"
MGUI=$(WOOTC_MANIFEST_BIN=/scripts/wootc-manifest WOOTC_HOST=/run/wootc/host \
       python3 /scripts/wootc-manifest-gui --self-test 2>&1)
check 'echo "$MGUI" | grep -q "self-test OK"' "manifest GUI: engine self-test passes (default-on selection)"

# ── 10. Account setup (identity pre-fill; the password is never persisted) ──
UGUI=$(WOOTC_IDENTITY_BIN=/scripts/wootc-identity WOOTC_HOST=/run/wootc/host \
       python3 /scripts/wootc-user-gui --self-test 2>&1)
check 'echo "$UGUI" | grep -q "self-test OK"' "user GUI: prefill + validation + secret handling"
# End-to-end in a real container: the saved record must not contain the secret.
WOOTC_ACCOUNT=/tmp/account.json python3 -c "
import types; ug = types.ModuleType('ug')
exec(open('/scripts/wootc-user-gui').read().split('def build_gui')[0], ug.__dict__)
ug.AccountEngine.save_identity({'username':'alice','password':'topsecret123'}, path='/tmp/account.json')"
check '! grep -q topsecret123 /tmp/account.json' "user GUI: password never written to the account file"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
INNER
)

podman run --rm --privileged \
    -v "$REPO_ROOT/payload/migration:/scripts:ro,Z" \
    "$IMG" bash -c "$INNER"
