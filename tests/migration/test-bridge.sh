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
if [ -d /scripts/plugins.d ]; then
    mkdir -p /usr/lib/wootc/plugins.d
    cp -a /scripts/plugins.d/* /usr/lib/wootc/plugins.d/ 2>/dev/null || true
fi

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

# ── 5c. App detection & pre-filled profile union (SPEC §4.3) ────────────────
mkdir -p "/run/wootc/host/Users/alice/AppData/Roaming/Code/User/snippets"
echo '{"editor.fontSize": 14}' > "/run/wootc/host/Users/alice/AppData/Roaming/Code/User/settings.json"
echo '[{"key": "ctrl+t", "command": "term"}]' > "/run/wootc/host/Users/alice/AppData/Roaming/Code/User/keybindings.json"
echo '{"hdr": {"prefix": "h"}}' > "/run/wootc/host/Users/alice/AppData/Roaming/Code/User/snippets/python.json"
mkdir -p "/run/wootc/host/Users/alice/.vscode/extensions/ms-python.python-2024.1.0"
mkdir -p "/run/wootc/host/Users/alice/AppData/Roaming/discord"
mkdir -p "/run/wootc/host/Users/alice/AppData/Roaming/Spotify"
mkdir -p "/run/wootc/host/Users/alice/AppData/Roaming/vlc"
mkdir -p "/run/wootc/host/Users/alice/AppData/Roaming/GIMP/2.10"
mkdir -p "/run/wootc/host/Users/alice/AppData/Roaming/obs-studio/basic/scenes"
mkdir -p "/run/wootc/host/wootc/install"
cat > "/run/wootc/host/wootc/install/programs.json" <<'REGJSON'
{
  "apps": [
    {"displayName": "Google Chrome", "publisher": "Google LLC"},
    {"displayName": "Mozilla Firefox", "publisher": "Mozilla"},
    {"displayName": "Visual Studio Code", "publisher": "Microsoft Corporation"},
    {"displayName": "Discord", "publisher": "Discord Inc."},
    {"displayName": "Spotify", "publisher": "Spotify Ltd"},
    {"displayName": "VLC media player", "publisher": "VideoLAN"},
    {"displayName": "LibreOffice", "publisher": "The Document Foundation"},
    {"displayName": "7-Zip", "publisher": "Igor Pavlov"},
    {"displayName": "OBS Studio", "publisher": "OBS Project"}
  ],
  "defaultBrowser": "ChromeHTML",
  "defaultMail": "ThunderbirdURL",
  "startupPrograms": ["Discord", "Spotify"]
}
REGJSON

bash /scripts/wootc-detect-apps alice >/dev/null 2>&1 || true
check "[ -f /home/alice/.config/wootc/bridge-apps.json ]" "App detection: bridge-apps.json recorded"
check "grep -q '\"app\":\"vscode\"' /home/alice/.config/wootc/bridge-apps.json" "App detection: VS Code detected"
check "grep -q '\"app\":\"discord\"' /home/alice/.config/wootc/bridge-apps.json" "App detection: Discord detected"
check "grep -q '\"app\":\"spotify\"' /home/alice/.config/wootc/bridge-apps.json" "App detection: Spotify detected"
check "grep -q '\"app\":\"libreoffice\"' /home/alice/.config/wootc/bridge-apps.json" "App detection: LibreOffice detected from registry manifest"
check "grep -q '\"app\":\"7zip\"' /home/alice/.config/wootc/bridge-apps.json" "App detection: 7-Zip detected from registry manifest"
check "[ -f /home/alice/.config/Code/User/settings.json ]" "App detection: VS Code settings.json copied"
check "[ -f /home/alice/.config/wootc/vscode-extensions.txt ]" "App detection: VS Code extension list saved"

# ── 6. Actual ESP shell consumer with a controlled test boundary ─────────
# These fixtures prove artifact routing/options and refusal before writes.
# The adapter is not EFI identity, signature, archive or firmware evidence.
# Actual controller/cryptographic controls are separate below and in unit tests.
mkdir -p /tmp/esp/EFI/wootc /tmp/esp/EFI/fedora /tmp/boot/loader/entries /tmp/boot/ostree/x
echo old-kernel > /tmp/esp/EFI/wootc/phase2-vmlinuz
echo old-initrd > /tmp/esp/EFI/wootc/phase2-initramfs.img
echo original-config > /tmp/esp/EFI/fedora/grub.cfg
echo new-kernel > /tmp/boot/ostree/x/vmlinuz-6.1
echo new-initrd > /tmp/boot/ostree/x/initramfs-6.1.img
cat > /tmp/boot/loader/entries/ostree-2.conf <<'BLS'
title wootc
version 2
linux /ostree/x/vmlinuz-6.1
initrd /ostree/x/initramfs-6.1.img
options root=UUID=abcd rw ostree=/ostree/boot.1
BLS
echo "root=UUID=abcd wootc.host_uuid=1234567890ABCDEF loop=/wootc/disks/root.disk" > /tmp/cmdline
cat > /tmp/fixture-esp-control <<'PYCONTROL'
#!/usr/bin/python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
with open('/tmp/fixture-control-calls','a') as stream:stream.write(json.dumps(args)+'\n')
if args[0]=='prepare':
    if os.environ.get('FIXTURE_REFUSE')=='1':raise SystemExit(1)
    cfg='../foreign/grub.cfg' if os.environ.get('FIXTURE_BAD_OUTPUT')=='1' else 'EFI/fedora/grub.cfg'
    print(json.dumps({'cfgs':[cfg],'chainChanged':False}))
elif args[0]=='write':
    destination=args[args.index('--destination')+1]
    if destination not in ('EFI/wootc/phase2-vmlinuz','EFI/wootc/phase2-initramfs.img','EFI/fedora/grub.cfg'):
        raise SystemExit('unexpected consumer destination')
    source=Path(args[args.index('--source')+1]);esp=Path(args[args.index('--esp')+1])
    (esp/destination).write_bytes(source.read_bytes())
else:raise SystemExit('unexpected adapter action')
PYCONTROL
chmod 755 /tmp/fixture-esp-control
fixture_sync() {
    WOOTC_ESP_DIR=/tmp/esp WOOTC_ESP_UUID=fixture WOOTC_BOOT_DIR=/tmp/boot \
    WOOTC_CMDLINE=/tmp/cmdline WOOTC_ESP_CONTROL=/tmp/fixture-esp-control \
        bash /scripts/wootc-esp-sync > /tmp/fixture-esp-sync.log 2>&1
}
# Refused preparation must leave all existing bytes unchanged.
FIXTURE_REFUSE=1
export FIXTURE_REFUSE
if fixture_sync; then bad "ESP consumer: refused preparation returned success"; else ok "ESP consumer: refused preparation reports failure"; fi
check '[ "$(cat /tmp/esp/EFI/wootc/phase2-vmlinuz)" = old-kernel ] && [ "$(cat /tmp/esp/EFI/fedora/grub.cfg)" = original-config ]' "ESP consumer: refused preparation writes no artifacts"
unset FIXTURE_REFUSE
FIXTURE_BAD_OUTPUT=1
export FIXTURE_BAD_OUTPUT
if fixture_sync; then bad "ESP consumer: malformed output returned success"; else ok "ESP consumer: malformed controller output reports failure"; fi
check '[ "$(cat /tmp/esp/EFI/wootc/phase2-vmlinuz)" = old-kernel ] && [ ! -e /tmp/esp/foreign ]' "ESP consumer: malformed output writes no artifacts"
unset FIXTURE_BAD_OUTPUT
fixture_sync
check '[ "$(cat /tmp/esp/EFI/wootc/phase2-vmlinuz)" = new-kernel ]' "ESP consumer: stale kernel refreshed from actual BLS entry"
check 'grep -q "loop=/wootc/disks/root.disk" /tmp/esp/EFI/fedora/grub.cfg' "ESP consumer: GRUB config carries actual loop args"
check 'python3 -c "import json;calls=[json.loads(line) for line in open(\"/tmp/fixture-control-calls\")];assert calls[2][0]==\"prepare\";assert all(call[0]==\"write\" for call in calls[3:])"' "ESP consumer: preparation precedes delegated writes"
# A foreign neighboring systemd file cannot override the observed shim route.
mkdir -p /tmp/esp/EFI/systemd
echo foreign-systemd > /tmp/esp/EFI/systemd/systemd-bootx64.efi
BOOTLOADER=systemd
export BOOTLOADER
fixture_sync
check '[ "$(cat /tmp/esp/EFI/systemd/systemd-bootx64.efi)" = foreign-systemd ] && [ ! -e /tmp/esp/loader ]' "ESP consumer: foreign systemd neighbor preserved without loader mutation"
unset BOOTLOADER
# This is classic kernel discovery only, not classic deployment support.
rm -rf /tmp/boot; mkdir -p /tmp/boot
echo classic-kernel > /tmp/boot/vmlinuz-6.2-generic
echo classic-initrd > /tmp/boot/initrd.img-6.2-generic
fixture_sync
check '[ "$(cat /tmp/esp/EFI/wootc/phase2-vmlinuz)" = classic-kernel ]' "ESP consumer: classic kernel discovery through controlled adapter"
# Actual installed controller must reject this container/fake-ESP identity.
# No missing library/dependency is accepted as a successful refusal.
before_kernel=$(sha256sum /tmp/esp/EFI/wootc/phase2-vmlinuz)
before_config=$(sha256sum /tmp/esp/EFI/fedora/grub.cfg)
if WOOTC_CHAIN_LIBRARY=/scripts/lib WOOTC_ESP_DIR=/tmp/esp WOOTC_ESP_UUID=fixture \
    WOOTC_BOOT_DIR=/tmp/boot WOOTC_CMDLINE=/tmp/cmdline \
    WOOTC_ESP_CONTROL=/usr/local/bin/wootc-esp-control \
    bash /scripts/wootc-esp-sync > /tmp/actual-controller-refusal.log 2>&1; then
    bad "Actual ESP controller: fake installed identity returned success"
else
    check 'grep -q "refusing refresh:.*root" /tmp/actual-controller-refusal.log' "Actual ESP controller: measured root identity refusal"
fi
check '[ "$(sha256sum /tmp/esp/EFI/wootc/phase2-vmlinuz)" = "$before_kernel" ] && [ "$(sha256sum /tmp/esp/EFI/fedora/grub.cfg)" = "$before_config" ]' "Actual ESP controller: refusal preserves all boot artifacts"

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

# ── #73: the single-user fallback, in its own container ──────────────────────
# The suite above uses a Windows profile whose name MATCHES the Linux user, so
# it can never exercise the mismatch. Enterprise/LTSC Windows media log on as
# "Docker" while the installer creates "wootc", and exact-name matching bridged
# NOTHING while still reporting success — a successful migration that carried
# none of the user's files. Fresh fixtures, because the case is defined by there
# being exactly one profile and exactly one account.
INNER73=$(cat <<'INNER'
set -Eeuo pipefail
PASS=0; FAIL=0
ok()  { echo "[PASS] $*"; PASS=$((PASS+1)); }
bad() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
check(){ if eval "$1"; then ok "$2"; else bad "$2"; fi; }

dnf install -y -q util-linux >/dev/null 2>&1 || true
cp /scripts/wootc-* /usr/local/bin/ && chmod +x /usr/local/bin/wootc-*

# One Windows profile ("Docker"), one Linux user ("wootc") — names differ.
useradd -m -u 1000 wootc
mkdir -p /run/wootc/host/Users/Docker/{Documents,Pictures}
mkdir -p /run/wootc/host/Users/Public/Documents      # system profile, ignored
echo "tax-return" > /run/wootc/host/Users/Docker/Documents/taxes.txt
# The script refuses to run unless /run/wootc/host is a real mountpoint
# (wootc-host-bind.service does this for real). Without it the guard exits
# first and every assertion below passes or fails for the wrong reason.
mount --bind /run/wootc/host /run/wootc/host

out=$(bash /usr/local/bin/wootc-mount-user-dirs 2>&1 || true)
echo "$out" | sed 's/^/    /'

check '[ -f /home/wootc/Documents/taxes.txt ]' \
    "#73: sole Windows profile bridges to the sole Linux user despite the name mismatch"
check 'echo "$out" | grep -q "exactly one Windows profile"' \
    "#73: the fallback says why it bridged"
check 'echo "$out" | grep -q "summary: [1-9]"' \
    "#73: the summary reports a non-zero bind count"

# Ambiguity must NOT be guessed at: two profiles, no name match -> bridge nothing.
umount /home/wootc/Documents 2>/dev/null || true
umount /home/wootc/Pictures  2>/dev/null || true
rm -rf /home/wootc/Documents /home/wootc/Pictures
mkdir -p /run/wootc/host/Users/Someone/Documents
out2=$(bash /usr/local/bin/wootc-mount-user-dirs 2>&1 || true)
check '[ ! -f /home/wootc/Documents/taxes.txt ]' \
    "#73: two candidate profiles and no name match bridges nothing rather than guessing"
# Must prove the script RAN — "nothing was bridged" is also what a script that
# aborted at its first guard produces, and that is a false pass.
check 'echo "$out2" | grep -q "summary:"' \
    "#73: the ambiguous run actually executed (not an early guard exit)"
check 'echo "$out2" | grep -q "cannot decide\|summary: 0"' \
    "#73: the ambiguous case says so instead of failing silently"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
INNER
)

podman run --rm --privileged \
    -v "$REPO_ROOT/payload/migration:/scripts:ro,Z" \
    "$IMG" bash -c "$INNER73"

# ── #64: OneDrive known-folder redirection ───────────────────────────────────
# The E2E seeds its canary straight into C:\Users\<u>\Documents on an image
# with no OneDrive account, so the redirected path is NEVER exercised there:
# every green we have proves the bridge works only where redirection does not
# apply. This is the one place that case can be tested at all.
INNER64=$(cat <<'INNER'
set -Eeuo pipefail
PASS=0; FAIL=0
ok()  { echo "[PASS] $*"; PASS=$((PASS+1)); }
bad() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
check(){ if eval "$1"; then ok "$2"; else bad "$2"; fi; }

dnf install -y -q util-linux python3 >/dev/null 2>&1 || true
cp /scripts/wootc-* /usr/local/bin/ && chmod +x /usr/local/bin/wootc-*

useradd -m -u 1000 alice
# OneDrive Backup redirects Documents; the literal folder is left behind as an
# empty stub, which is exactly what makes the old behaviour so damaging.
mkdir -p /run/wootc/host/Users/alice/Documents
mkdir -p /run/wootc/host/Users/alice/OneDrive/Documents
mkdir -p /run/wootc/host/Users/alice/Pictures
echo "the real tax return" > /run/wootc/host/Users/alice/OneDrive/Documents/taxes.txt
echo "holiday"             > /run/wootc/host/Users/alice/Pictures/holiday.jpg
mkdir -p /run/wootc/host/wootc
cat > /run/wootc/host/wootc/known-folders.json <<'JSON'
{
  "user": "alice",
  "folders": {
    "Documents": "C:\\Users\\alice\\OneDrive\\Documents",
    "Pictures": "C:\\Users\\alice\\Pictures"
  },
  "redirected": ["Documents"]
}
JSON
mount --bind /run/wootc/host /run/wootc/host

out=$(bash /usr/local/bin/wootc-mount-user-dirs 2>&1 || true)
echo "$out" | sed 's/^/    /'

check '[ "$(cat /home/alice/Documents/taxes.txt 2>/dev/null)" = "the real tax return" ]' \
    "#64: a OneDrive-redirected Documents bridges the REAL files, not the empty stub"
check '[ -f /home/alice/Pictures/holiday.jpg ]' \
    "#64: a non-redirected folder still bridges from the literal profile path"
check 'echo "$out" | grep -q "redirected: Documents"' \
    "#64: the redirect is stated in the log, not applied silently"
# The bridge must survive folders the manifest does not mention. Without this,
# a helper returning non-zero for "no redirect" aborts the run under set -e
# after the first few binds — and a partial migration looks like a working one.
check 'echo "$out" | grep -q "summary:"' \
    "#64: folders absent from the manifest do not abort the run"

# A manifest belonging to a DIFFERENT user must never redirect this one, or
# account A's OneDrive lands in account B's home.
umount /home/alice/Documents 2>/dev/null || true
umount /home/alice/Pictures 2>/dev/null || true
python3 - <<'PYFIX'
import json
p = "/run/wootc/host/wootc/known-folders.json"
d = json.load(open(p)); d["user"] = "someone-else"
json.dump(d, open(p, "w"))
PYFIX
out2=$(bash /usr/local/bin/wootc-mount-user-dirs 2>&1 || true)
check 'echo "$out2" | grep -q "summary:"' \
    "#64: the cross-user run actually executed"
check '[ ! -f /home/alice/Documents/taxes.txt ]' \
    "#64: a manifest for another user does not redirect this user's folders"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
INNER
)

podman run --rm --privileged \
    -v "$REPO_ROOT/payload/migration:/scripts:ro,Z" \
    "$IMG" bash -c "$INNER64"

# ── #62: bridge handles missing home directory gracefully ───────────────────
# ── #66: Cloud-drive disclosure ─────────────────────────────────────────────
# Combined regression block: the bridge must (a) detect a matching user with
# no home directory and continue (not silently exit 0), and (b) ingest the
# Phase-1 cloud-drives.json manifest and surface each provider's shape —
# including Google Drive's virtual-drive letter — in the journal.
INNER=$(cat <<'INNER'
set -Eeuo pipefail
PASS=0; FAIL=0
ok()  { echo "[PASS] $*"; PASS=$((PASS+1)); }
bad() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
check(){ if eval "$1"; then ok "$2"; else bad "$2"; fi; }

dnf install -y -q util-linux python3 >/dev/null 2>&1 || true
cp /scripts/wootc-* /usr/local/bin/ && chmod +x /usr/local/bin/wootc-*

# #62 fixture: a matching user with NO home directory at the path passwd
# advertises (deployment bug from run 20260723T0423 where fisherman's useradd
# put home in the wrong var/).
useradd -M -u 1000 brokenuser
mkdir -p /run/wootc/host/Users/brokenuser/{Documents,Pictures}
echo "tax-return" > /run/wootc/host/Users/brokenuser/Documents/taxes.txt

# #66 fixture: a normal user whose profile lives on the host, plus a
# cloud-drives.json manifest (OneDrive real folder, Google Drive virtual G:,
# Dropbox real folder).
useradd -m -u 1001 alice
mkdir -p /run/wootc/host/Users/alice/Documents
echo "tax-return" > /run/wootc/host/Users/alice/Documents/taxes.txt
mkdir -p /run/wootc/host/wootc
cat > /run/wootc/host/wootc/cloud-drives.json <<'JSON'
{
  "drives": [
    {
      "provider": "onedrive",
      "account": "Personal",
      "rootPath": "C:\\Users\\alice\\OneDrive",
      "virtualDrive": false,
      "localBytes": 1048576,
      "cloudOnly": 12
    },
    {
      "provider": "googledrive",
      "account": "Google Drive",
      "rootPath": "G:",
      "virtualDrive": true,
      "localBytes": -1,
      "cloudOnly": 0,
      "note": "Virtual drive — content is only available while Drive for desktop is running. Requires sign-in on Linux."
    },
    {
      "provider": "dropbox",
      "account": "personal",
      "rootPath": "C:\\Users\\alice\\Dropbox",
      "virtualDrive": false,
      "localBytes": 524288,
      "cloudOnly": 0
    }
  ]
}
JSON
mount --bind /run/wootc/host /run/wootc/host

out=$(bash /usr/local/bin/wootc-mount-user-dirs 2>&1 || true)
echo "$out" | sed 's/^/    /'

# ── #62 checks ──
check 'echo "$out" | grep -q "has no home directory"' \
    "#62: bridge detects missing home for matching user instead of exiting silently"
check 'echo "$out" | grep -q "summary:"' \
    "#62: bridge still produces a summary after encountering a missing home"
check '! mountpoint -q /home/brokenuser/Documents 2>/dev/null' \
    "#62: folders are NOT bound when the home directory does not exist"

# ── #66 checks ──
check 'echo "$out" | grep -q "cloud providers detected"' \
    "#66: cloud-drives.json is found and ingested"
check 'echo "$out" | grep -q "onedrive.*OneDrive.*folder"' \
    "#66: OneDrive shown as a real folder path"
check 'echo "$out" | grep -q "googledrive.*G:.*virtual"' \
    "#66: Google Drive shown with its virtual drive letter"
check 'echo "$out" | grep -q "dropbox.*Dropbox.*folder"' \
    "#66: Dropbox shown as a real folder path"
check 'echo "$out" | grep -q "Requires sign-in on Linux"' \
    "#66: Google Drive virtual-drive note is surfaced for the user"

# An empty manifest (no cloud drives found) must not crash.
cat > /run/wootc/host/wootc/cloud-drives.json <<'JSON'
{"drives": []}
JSON
out2=$(bash /usr/local/bin/wootc-mount-user-dirs 2>&1 || true)
check 'echo "$out2" | grep -q "cloud providers detected"' \
    "#66: empty manifest still ingested (so the journal shows the scan ran)"
check 'echo "$out2" | grep -q "summary:"' \
    "#66: empty cloud-drives does not abort the bridge"

# A missing manifest must not crash or log a cloud-drive section.
rm -f /run/wootc/host/wootc/cloud-drives.json   # out3 must run with NO manifest
out3=$(bash /usr/local/bin/wootc-mount-user-dirs 2>&1 || true)
check '! echo "$out3" | grep -q "cloud providers"' \
    "#66: no manifest at all is cleanly silent (not an error)"
check 'echo "$out3" | grep -q "summary:"' \
    "#66: missing manifest does not abort the bridge"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
INNER
)

podman run --rm --privileged \
    -v "$REPO_ROOT/payload/migration:/scripts:ro,Z" \
    "$IMG" bash -c "$INNER"
