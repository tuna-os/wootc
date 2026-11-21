#!/usr/bin/env bats
# app-flatpaks.bats — the Windows apps → Flatpak path (SPEC §4.3).
#
# The user confirms apps on Windows; the deployer installs their Flatpaks into
# the target (payload/deployer/flatpak-install.sh) and writes a receipt;
# wootc-detect-apps reports per app whether the Flatpak is really there; and
# Phase 3 carries the Phase-2 installation to the native disk. Every status
# here must come from the target's Flatpak installation, never from an exit
# code or from what was requested.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    LIB="$REPO_ROOT/payload/deployer/flatpak-install.sh"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    MAP="$REPO_ROOT/app/data/app-flatpaks.json"
    DETECT="$REPO_ROOT/payload/migration/wootc-detect-apps"
    GN="$REPO_ROOT/payload/migration/wootc-go-native"
    TMP="$BATS_TEST_TMPDIR"
    # Stubs must execute, or every assertion that reads their record passes
    # vacuously (a noexec /tmp, see go-native.bats).
    STUBDIR="$TMP/stubs"; mkdir -p "$STUBDIR"
    printf '#!/bin/bash\ntrue\n' >"$STUBDIR/.probe"; chmod +x "$STUBDIR/.probe"
    if ! "$STUBDIR/.probe" 2>/dev/null; then
        STUBDIR="$HOME/.cache/wootc-bats-stubs.$$"; mkdir -p "$STUBDIR"
        printf '#!/bin/bash\ntrue\n' >"$STUBDIR/.probe"; chmod +x "$STUBDIR/.probe"
        "$STUBDIR/.probe" 2>/dev/null || { echo "FATAL: stubs cannot execute" >&2; return 1; }
    fi
    VAR="$TMP/target/var"; ETC="$TMP/target/etc"; NTFS="$TMP/ntfs/wootc/install"
    mkdir -p "$VAR" "$ETC" "$NTFS"
    CALLS="$TMP/calls"; : >"$CALLS"
    LOG="$TMP/log"; : >"$LOG"
}

# install_with <apps.json body> [stub settings...]
# Runs install_selected_flatpaks against a fake image. The fake flatpak
# "installs" an app by creating its directory, and `flatpak info` answers from
# that directory, so the receipt can only be right if it asks info.
#   FAIL_IDS       ids whose install fails (no directory)
#   EXIT0_NOAPP    ids whose install exits 0 but installs nothing
#   EXIT1_APP      ids whose install exits 1 but did install
#   REMOTE_FAILS   remote-add fails
#   LABEL          what the label step prints last (default: a context)
install_with() {
    printf '%s\n' "$1" >"$NTFS/apps.json"
    run bash -c '
        set -Eeuo pipefail
        log() { printf "%s\n" "$*" >>"$LOG"; }
        err() { printf "%s\n" "$*" >>"$LOG"; }
        source "$LIB"
        flatpak_image_ready() { return 0; }
        flatpak_in_image() {
            printf "%s\n" "$*" >>"$CALLS"
            [[ "$1" == sh ]] && { printf "%s\n" "${LABEL:-system_u:object_r:var_lib_t:s0 /var/lib/flatpak/repo}"; [[ "${LABEL:-}" == "" ]]; return; }
            case "$2" in
                remote-add) [[ -z "${REMOTE_FAILS:-}" ]] || { echo "error: Unable to load summary from remote flathub: Could not resolve hostname"; return 1; } ;;
                install)
                    local id=${!#}
                    if [[ " ${FAIL_IDS:-} " == *" $id "* ]]; then echo "Looking for matches..."; echo "error: No remote refs found for $id"; return 1; fi
                    [[ " ${EXIT0_NOAPP:-} " == *" $id "* ]] && return 0
                    mkdir -p "$FLATPAK_DIR/app/$id"
                    [[ " ${EXIT1_APP:-} " == *" $id "* ]] && { echo "Warning: triggers failed"; return 1; }
                    return 0 ;;
                info) [[ -d "$FLATPAK_DIR/app/${!#}" ]] ;;
            esac
        }
        install_selected_flatpaks "$NTFS/apps.json" "$MAP" localhost/image "$VAR" "$ETC" "$NTFS/flatpak-install.json"
    '
}

export_env() {
    export LIB MAP VAR ETC NTFS CALLS LOG
    export WOOTC_FLATPAK_ATTEMPTS=2 WOOTC_FLATPAK_BACKOFF=0
    # The deployer's disk-backed scratch that holds the flatpak /var/tmp.
    export TMPDIR="$TMP/scratch"; mkdir -p "$TMPDIR"
}

receipt() { jq -c "$1" "$ETC/wootc/flatpak-install.json"; }

@test "one app that cannot install fails soft: the others install and the receipt names it" {
    export_env
    FAIL_IDS="org.gimp.GIMP" install_with \
        '{"schemaVersion":1,"remote":"flathub","remoteUrl":"https://dl.flathub.org/repo/flathub.flatpakrepo","flatpaks":["org.audacityteam.Audacity","org.gimp.GIMP","org.inkscape.Inkscape"]}'
    cat "$LOG"
    [ "$status" -eq 0 ]
    [ "$(receipt .schemaVersion)" = 1 ]
    [ "$(receipt .requested)" = '["org.audacityteam.Audacity","org.gimp.GIMP","org.inkscape.Inkscape"]' ]
    [ "$(receipt .installed)" = '["org.audacityteam.Audacity","org.inkscape.Inkscape"]' ]
    [ "$(receipt '[.failed[].id]')" = '["org.gimp.GIMP"]' ]
    [[ "$(receipt '.failed[0].error')" == *"No remote refs found"* ]]
    # The serial lines the E2E reads.
    grep -Fxq "  wootc: flatpak installed: org.audacityteam.Audacity" "$LOG"
    grep -Fxq "  wootc: flatpak installed: org.inkscape.Inkscape" "$LOG"
    grep -q "^  wootc: flatpak FAILED: org.gimp.GIMP: .*No remote refs found" "$LOG"
    # Bounded retries: the failing app was tried exactly WOOTC_FLATPAK_ATTEMPTS times.
    [ "$(grep -c '^flatpak install --system --noninteractive -y flathub org.gimp.GIMP$' "$CALLS")" -eq 2 ]
    # Same receipt on the Windows volume, and the requested list persisted.
    cmp "$ETC/wootc/flatpak-install.json" "$NTFS/flatpak-install.json"
    [ "$(cat "$ETC/wootc/flatpaks.list")" = "$(printf '%s\n' org.audacityteam.Audacity org.gimp.GIMP org.inkscape.Inkscape)" ]
    # The flathub remote is added to the TARGET installation first.
    head -1 "$CALLS" | grep -Fxq "flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
}

@test "installed means flatpak info finds the app in the target, not the install's exit status" {
    export_env
    EXIT0_NOAPP="org.gimp.GIMP" EXIT1_APP="org.inkscape.Inkscape" install_with \
        '{"schemaVersion":1,"flatpaks":["org.gimp.GIMP","org.inkscape.Inkscape"]}'
    [ "$status" -eq 0 ]
    [ "$(receipt .installed)" = '["org.inkscape.Inkscape"]' ]
    [ "$(receipt '[.failed[].id]')" = '["org.gimp.GIMP"]' ]
    [[ "$(receipt '.failed[0].error')" == *"flatpak info --system does not find it"* ]]
}

@test "only IDs in the app map are installed; others fail without a download" {
    export_env
    install_with '{"schemaVersion":1,"flatpaks":["org.audacityteam.Audacity","com.example.NotInMap","not-an-id","org.audacityteam.Audacity","","@","x.y\nz.w"]}'
    [ "$status" -eq 0 ]
    [ "$(receipt .requested)" = '["org.audacityteam.Audacity","com.example.NotInMap","not-an-id","@","x.y?z.w"]' ]
    [ "$(receipt .installed)" = '["org.audacityteam.Audacity"]' ]
    [ "$(receipt '[.failed[] | .id + "=" + .error]')" = '["com.example.NotInMap=not in the wootc app map","not-an-id=not a Flatpak application ID","@=not a Flatpak application ID","x.y?z.w=not a Flatpak application ID"]' ]
    [ "$(grep -c 'NotInMap\|not-an-id\|x\.y' "$CALLS")" -eq 0 ]
    [ "$(grep -c '^flatpak install' "$CALLS")" -eq 1 ]
}

@test "an empty selection writes an empty receipt and runs no container" {
    export_env
    install_with '{"schemaVersion":1,"remote":"flathub","flatpaks":[]}'
    [ "$status" -eq 0 ]
    [ "$(receipt .)" = '{"schemaVersion":1,"requested":[],"installed":[],"failed":[]}' ]
    [ ! -s "$CALLS" ]
    [ ! -s "$ETC/wootc/flatpaks.list" ]
}

@test "no apps.json from an older installer: nothing installed, no receipt, deploy continues" {
    export_env
    run bash -c 'log() { echo "$*"; }; err() { echo "$*"; }; source "$LIB"
        install_selected_flatpaks "$NTFS/absent.json" "$MAP" img "$VAR" "$ETC" "$NTFS/flatpak-install.json"'
    [ "$status" -eq 0 ]
    [ ! -e "$ETC/wootc/flatpak-install.json" ]
    [ ! -e "$NTFS/flatpak-install.json" ]
}

@test "a remote that cannot be added fails every app with the reason" {
    export_env
    REMOTE_FAILS=1 install_with '{"schemaVersion":1,"flatpaks":["org.gimp.GIMP","org.inkscape.Inkscape"]}'
    [ "$status" -eq 0 ]
    [ "$(receipt .installed)" = '[]' ]
    [ "$(receipt '[.failed[] | select(.error | test("cannot add the flathub remote: .*Could not resolve hostname")) | .id]')" = '["org.gimp.GIMP","org.inkscape.Inkscape"]' ]
    [ "$(grep -c '^flatpak install' "$CALLS")" -eq 0 ]
}

@test "installed apps are labeled; unlabeled apps on an enforcing target are not reported installed" {
    export_env
    install_with '{"schemaVersion":1,"flatpaks":["org.gimp.GIMP"]}'
    [ "$(receipt .installed)" = '["org.gimp.GIMP"]' ]
    grep -q '^sh -c' "$CALLS"
    grep -Fq 'setfiles -F "$fc" /var/lib/flatpak' "$CALLS"
    grep -Fq "wootc: flatpak SELinux labels applied (system_u:object_r:var_lib_t:s0 /var/lib/flatpak/repo)" "$LOG"

    rm -rf "$VAR" "$ETC"; mkdir -p "$VAR" "$ETC/selinux"; : >"$LOG"
    echo SELINUX=enforcing >"$ETC/selinux/config"
    LABEL="no setfiles in the image" install_with '{"schemaVersion":1,"flatpaks":["org.gimp.GIMP"]}'
    [ "$status" -eq 0 ]
    [ "$(receipt .installed)" = '[]' ]
    [[ "$(receipt '.failed[0].error')" == *"SELinux labels could not be applied (no setfiles in the image)"* ]]

    rm -rf "$VAR" "$ETC"; mkdir -p "$VAR" "$ETC/selinux"
    echo SELINUX=permissive >"$ETC/selinux/config"
    LABEL="no setfiles in the image" install_with '{"schemaVersion":1,"flatpaks":["org.gimp.GIMP"]}'
    [ "$(receipt .installed)" = '["org.gimp.GIMP"]' ]
}

@test "the target's Flatpak installation is the /var the installed system boots with" {
    run bash -c 'source "$1"
        flatpak_target_var /mnt/verify /mnt/verify/ostree/deploy/default/deploy/abc123.0
        mkdir -p "$2/state/deploy/h"
        flatpak_target_var "$2" "$2/state/deploy/h"
        flatpak_target_var /mnt/verify /mnt/verify' _ "$LIB" "$TMP/cfs"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = /mnt/verify/ostree/deploy/default/var ]
    [ "${lines[1]}" = "$TMP/cfs/state/os/default/var" ]
    [ "${lines[2]}" = /mnt/verify/var ]
}

@test "the default runner installs from the deployed image into the target's flatpak dir" {
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$CALLS" >"$STUBDIR/podman"
    printf '#!/bin/bash\nshift; exec "$@"\n' >"$STUBDIR/timeout"
    chmod +x "$STUBDIR/podman" "$STUBDIR/timeout"
    run bash -c 'PATH="$2:$PATH"; source "$1"; FLATPAK_IMAGE=localhost/wootc-ntfs-injected FLATPAK_DIR=/mnt/verify/ostree/deploy/default/var/lib/flatpak
        FLATPAK_TMP=/var/tmp/wootc-flatpak-tmp.abc
        flatpak_in_image flatpak info --system org.gimp.GIMP' _ "$LIB" "$STUBDIR"
    [ "$status" -eq 0 ]
    grep -Fxq "run --rm --network=host --privileged --security-opt label=disable -v /mnt/verify/ostree/deploy/default/var/lib/flatpak:/var/lib/flatpak -v /var/tmp/wootc-flatpak-tmp.abc:/var/tmp --entrypoint flatpak localhost/wootc-ntfs-injected info --system org.gimp.GIMP" "$CALLS"
}

# Probe 44889931801 (bluefin:stable): both apps failed three times with
#   Error: Failed to install org.gnome.Platform: While pulling
#   runtime/org.gnome.Platform/x86_64/50 from remote flathub:
#   open(O_TMPFILE): No such file or directory
# The image's /var is empty, and libostree decompresses each LZMA delta part
# into an O_TMPFILE in /var/tmp. The fake podman below is such an image: its
# flatpak install fails exactly so unless the run gives it a writable /var/tmp.
@test "an image with an empty /var still installs: the runner gives flatpak a /var/tmp from the deployer's scratch" {
    export_env
    cat >"$STUBDIR/podman" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$CALLS"
[[ "$1" == image ]] && exit 0
[[ "$1" == run ]] || exit 125
shift
fp="" vartmp=""
while (( $# )); do
    case "$1" in
        -v) case "${2#*:}" in
                /var/lib/flatpak) fp=${2%%:*} ;;
                /var/tmp) vartmp=${2%%:*} ;;
            esac
            # podman refuses a bind source that does not exist.
            [[ -e "${2%%:*}" ]] || { echo "Error: statfs ${2%%:*}: no such file or directory"; exit 125; }
            shift 2 ;;
        --entrypoint) prog=$2; shift 3; break ;;
        *) shift ;;
    esac
done
case "$prog $1" in
    "flatpak remote-add") exit 0 ;;
    "flatpak install")
        if [[ -z "$vartmp" || ! -w "$vartmp" ]]; then
            echo "Error: Failed to install org.gnome.Platform: While pulling runtime/org.gnome.Platform/x86_64/50 from remote flathub: open(O_TMPFILE): No such file or directory"
            exit 1
        fi
        printf '%s\n' "$vartmp" >>"$CALLS.vartmp"
        : >"$vartmp/delta-part"
        mkdir -p "$fp/app/${!#}" ;;
    "flatpak info") [[ -d "$fp/app/${!#}" ]] ;;
    "sh -c") echo "system_u:object_r:var_lib_t:s0 /var/lib/flatpak/repo" ;;
    *) exit 1 ;;
esac
STUB
    printf '#!/bin/bash\nshift; exec "$@"\n' >"$STUBDIR/timeout"
    chmod +x "$STUBDIR/podman" "$STUBDIR/timeout"
    printf '%s\n' '{"schemaVersion":1,"remote":"flathub","remoteUrl":"https://dl.flathub.org/repo/flathub.flatpakrepo","flatpaks":["org.audacityteam.Audacity","org.inkscape.Inkscape"]}' >"$NTFS/apps.json"
    run bash -c 'PATH="$1:$PATH"
        log() { printf "%s\n" "$*" >>"$LOG"; }
        err() { printf "%s\n" "$*" >>"$LOG"; }
        source "$LIB"
        install_selected_flatpaks "$NTFS/apps.json" "$MAP" localhost/image "$VAR" "$ETC" "$NTFS/flatpak-install.json"' _ "$STUBDIR"
    cat "$LOG"
    [ "$status" -eq 0 ]
    [ "$(receipt .installed)" = '["org.audacityteam.Audacity","org.inkscape.Inkscape"]' ]
    [ "$(receipt .failed)" = '[]' ]
    # The /var/tmp lives in the deployer's scratch (TMPDIR), not in the
    # target, and is gone once the install is done.
    [ "$(sort -u "$CALLS.vartmp" | wc -l)" -eq 1 ]
    [[ "$(head -1 "$CALLS.vartmp")" == "$TMPDIR"/wootc-flatpak-tmp.* ]]
    [ -z "$(ls -A "$TMPDIR")" ]
    [ ! -e "$VAR/tmp" ]
}

@test "deploy.sh installs the selection after the ESP staging, before the relabel, and fisherman copies none" {
    grep -Fq 'source "${WOOTC_FLATPAK_INSTALL_FILE:-/usr/libexec/wootc-flatpak-install.sh}"' "$DEPLOY"
    grep -Fq '"flatpaks": []${USER_JSON}${BUNDLE_JSON}' "$DEPLOY"
    [ "$(grep -c 'wootc\.flatpaks' "$DEPLOY")" -eq 0 ]
    call=$(grep -n '^    install_selected_flatpaks /mnt/ntfs/wootc/install/apps.json' "$DEPLOY" | cut -d: -f1)
    esp=$(grep -n 'esp-manifest"$' "$DEPLOY" | tail -1 | cut -d: -f1)
    relabel=$(grep -n 'setfiles -F "$SELINUX_FILE_CONTEXTS"' "$DEPLOY" | cut -d: -f1)
    [ -n "$call" ] && [ -n "$esp" ] && [ -n "$relabel" ]
    [ "$esp" -lt "$call" ] && [ "$call" -lt "$relabel" ]
    sed -n "${call},$((call + 3))p" "$DEPLOY" | grep -Fq '/mnt/ntfs/wootc/install/flatpak-install.json'
}

@test "the deployer initramfs and the target carry the library and the app map" {
    grep -Fxq 'COPY payload/deployer/flatpak-install.sh /usr/libexec/wootc-flatpak-install.sh' "$REPO_ROOT/payload/deployer/Containerfile"
    grep -Fxq 'COPY app/data/app-flatpaks.json /usr/lib/wootc/migration/lib/app-flatpaks.json' "$REPO_ROOT/payload/deployer/Containerfile"
    grep -Fq 'wootc-flatpak-install.sh; do' "$REPO_ROOT/payload/deployer/Containerfile"
    grep -Fq 'usr/lib/wootc/migration/lib/app-flatpaks.json" ||' "$REPO_ROOT/payload/deployer/Containerfile"
    grep -Fxq '    inst_simple /usr/libexec/wootc-flatpak-install.sh' "$REPO_ROOT/payload/deployer/module-setup.sh"
    grep -Fxq '    inst_simple /usr/lib/wootc/migration/lib/app-flatpaks.json || return 1' "$REPO_ROOT/payload/deployer/module-setup.sh"
    grep -Fq '"$DEPLOY_ROOT/var/usrlocal/lib/wootc/app-flatpaks.json"' "$DEPLOY"
}

@test "app map: one entry per key, valid Flatpak IDs, and the E2E apps by their DisplayNames" {
    run python3 - "$MAP" <<'PY'
import json, re, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert doc["schemaVersion"] == 1
apps = doc["apps"]
keys = [a["key"] for a in apps]
assert len(keys) == len(set(keys)), keys
for a in apps:
    assert set(a) <= {"key", "name", "flatpak", "match", "session", "note"}, a
    assert re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}", a["flatpak"]), a
    assert a["name"] and a["match"] and all(m == m.lower() and m for m in a["match"]), a
def first(display):
    lower = display.lower()
    return next((a["flatpak"] for a in apps if any(m in lower for m in a["match"])), None)
expect = {
    "GIMP 2.10.36": "org.gimp.GIMP",
    "Inkscape 1.4.2": "org.inkscape.Inkscape",
    "Audacity 3.7.1": "org.audacityteam.Audacity",
    "VLC media player": "org.videolan.VLC",
    # On every Windows 11 machine: must not pre-install anything.
    "Microsoft Edge": None,
    "Microsoft Edge WebView2 Runtime": None,
    "Logitech G HUB": None,
}
for display, flatpak in expect.items():
    assert first(display) == flatpak, (display, first(display))
PY
    echo "$output"
    [ "$status" -eq 0 ]
}

# detect_with <programs.json apps> — run wootc-detect-apps for a fixture
# Windows user with a fake flatpak that knows only org.gimp.GIMP.
detect_with() {
    HOST="$TMP/host"; HOMEDIR="$TMP/home"
    mkdir -p "$HOST/Users/alice" "$HOST/wootc/install" "$HOMEDIR"
    printf '{"apps":%s}\n' "$1" >"$HOST/wootc/install/programs.json"
    printf '#!/bin/bash\nexit 0\n' >"$STUBDIR/mountpoint"
    printf '#!/bin/bash\necho "alice:x:%s:%s::%s:/bin/bash"\n' "$(id -u)" "$(id -g)" "$HOMEDIR" >"$STUBDIR/getent"
    printf '#!/bin/bash\necho "flatpak $*" >>"%s"\n[[ "$*" == "info --system org.gimp.GIMP" ]]\n' "$CALLS" >"$STUBDIR/flatpak"
    chmod +x "$STUBDIR/mountpoint" "$STUBDIR/getent" "$STUBDIR/flatpak"
    run env PATH="$STUBDIR:$PATH" WOOTC_HOST="$HOST" bash "$DETECT" alice alice
}

@test "detect-apps matches registry DisplayNames through the shared app map" {
    detect_with '[{"displayName":"GIMP 2.10.36"},{"displayName":"Inkscape 1.4.2"},{"displayName":"Microsoft Edge"},{"displayName":"Logitech G HUB"}]'
    echo "$output"
    [ "$status" -eq 0 ]
    apps="$HOMEDIR/.config/wootc/bridge-apps.json"
    [ "$(jq -c '[.apps[] | {app, flatpak, installed}]' "$apps")" = \
      '[{"app":"edge","flatpak":"com.google.Chrome","installed":false},{"app":"gimp","flatpak":"org.gimp.GIMP","installed":true},{"app":"inkscape","flatpak":"org.inkscape.Inkscape","installed":false}]' ]
    [ "$(jq -r '.apps[] | select(.app == "gimp") | .note' "$apps")" = "$(jq -r '.apps[] | select(.key == "gimp") | .note' "$MAP")" ]
    # One question per Flatpak, to the system installation.
    [ "$(grep -c '^flatpak info --system org.gimp.GIMP$' "$CALLS")" -eq 1 ]
    [ "$(grep -c 'DISPLAYNAME_TO_APP' "$DETECT")" -eq 0 ]
}

@test "detect-apps without the app map still records AppData apps and says why registry apps are missing" {
    mkdir -p "$TMP/host/Users/alice/AppData/Roaming/audacity"
    # A copy with its safety library beside it but no app map anywhere it looks.
    mkdir -p "$TMP/bin/lib"
    cp "$DETECT" "$TMP/bin/wootc-detect-apps"
    cp "$REPO_ROOT/payload/migration/lib/wootc_import_safety.py" "$TMP/bin/lib/"
    [ ! -e /usr/lib/wootc/migration/lib/app-flatpaks.json ] || skip "this host has an installed app map"
    DETECT="$TMP/bin/wootc-detect-apps" detect_with '[{"displayName":"GIMP 2.10.36"}]'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"app-flatpaks.json is not installed"* ]]
    [ "$(jq -c '[.apps[] | {app, installed}]' "$HOMEDIR/.config/wootc/bridge-apps.json")" = '[{"app":"audacity","installed":false}]' ]
}

@test "Phase 3 carries the Phase-2 Flatpak apps and checks each on the native disk" {
    printf '#!/bin/bash\necho "flatpak $* dir=${FLATPAK_SYSTEM_DIR:-}" >>"%s"\ncase "$*" in\n  "list --system --app --columns=application") printf "org.gimp.GIMP\\norg.inkscape.Inkscape\\n\\n" ;;\n  "info --system org.gimp.GIMP") [[ -n "$FLATPAK_SYSTEM_DIR" ]] ;;\n  *) exit 1 ;;\nesac\n' "$CALLS" >"$STUBDIR/flatpak"
    chmod +x "$STUBDIR/flatpak"
    # After sourcing: the script puts the system sbin/bin dirs first.
    run bash -c 'source "$1"; PATH="$2:$PATH"; phase2_flatpak_apps' _ "$GN" "$STUBDIR"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' org.gimp.GIMP org.inkscape.Inkscape)" ]
    run bash -c 'source "$1"; PATH="$2:$PATH"; verify_native_flatpaks /run/wootc-native/ostree/deploy/default/var/lib/flatpak org.gimp.GIMP org.inkscape.Inkscape' _ "$GN" "$STUBDIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"wootc: native flatpak present: org.gimp.GIMP"* ]]
    [[ "$output" == *"WARN: wootc: native flatpak MISSING: org.inkscape.Inkscape"* ]]
    grep -Fxq "flatpak info --system org.gimp.GIMP dir=/run/wootc-native/ostree/deploy/default/var/lib/flatpak" "$CALLS"
    # The recipe carries the list: [] would make fisherman copy nothing.
    grep -Fq '"flatpaks": ${gflatpakjson}$guserjson' "$GN"
}
