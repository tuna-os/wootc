#!/usr/bin/env bats
#
# The deployer proves the installed system's Python can import the helpers it
# staged in /var/usrlocal/lib/wootc. On a composefs deployment it chrooted
# into /state/deploy/<hash>, which holds only that deployment's state and no
# /usr, so every composefs install failed "target image lacks Python 3" even
# when the image ships it (#748: grouper:gnome has python3.14). The check now
# runs the image itself for a composefs deployment and keeps the chroot for an
# ostree or classic one. These stubs act like the real tools: chroot fails
# when the root has no such binary, and podman runs the -c code against the
# directory mounted with -v.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    WORK="$(mktemp -d)"
    mkdir -p "$WORK/bin"
    export CALLS="$WORK/calls"
    : > "$CALLS"
    export TMPDIR="$WORK"
    export PATH="$WORK/bin:$PATH"
    export IMAGE="ghcr.io/tuna-os/grouper:gnome"
    PYTHON3="$(command -v python3)"

    cat > "$WORK/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$CALLS"
if [ -n "${PODMAN_FAIL:-}" ]; then echo "$PODMAN_FAIL" >&2; exit 125; fi
map="" code=""
while [ $# -gt 0 ]; do
    case "$1" in
        -v) map=$2; shift 2 ;;
        -c) code=$2; shift 2 ;;
        *) shift ;;
    esac
done
host=${map%%:*} rest=${map#*:}
exec python3 -c "${code//${rest%%:*}/$host}"
EOF
    cat > "$WORK/bin/chroot" <<'EOF'
#!/usr/bin/env bash
root=$1; shift
echo "chroot $root $*" >> "$CALLS"
if [ ! -x "$root$1" ]; then
    echo "chroot: failed to run command '$1': No such file or directory" >&2
    exit 127
fi
shift 2
exec python3 -c "${1//\/var\/usrlocal\/lib\/wootc/$root/var/usrlocal/lib/wootc}"
EOF
    chmod +x "$WORK/bin/podman" "$WORK/bin/chroot"
}

teardown() {
    rm -rf "$WORK"
}

load_helper() {
    {
        sed -n '/^PROBE_ERR=/p' "$DEPLOY"
        echo 'acquire_image() { echo "acquire $1" >> "$CALLS"; }'
        sed -n '/^target_python_imports() {/,/^}/p' "$DEPLOY"
    } > "$WORK/helper.sh"
    # shellcheck disable=SC1091
    source "$WORK/helper.sh"
}

stage_helpers() {  # <deployment root>
    mkdir -p "$1/var/usrlocal/lib/wootc"
    cp "$REPO_ROOT"/payload/migration/lib/*.py "$1/var/usrlocal/lib/wootc/"
}

@test "a composefs deployment imports the staged collector with the image's Python, not by chroot" {
    load_helper
    COMPOSEFS=1
    DEPLOY_ROOT="$WORK/mnt/verify/state/deploy/0f8ea28c"
    stage_helpers "$DEPLOY_ROOT"
    run target_python_imports wootc_firstboot_evidence
    [ "$status" -eq 0 ]
    grep -qx "acquire target Python check" "$CALLS"
    grep -qF -- "podman run --rm --network=host -v $DEPLOY_ROOT/var/usrlocal/lib/wootc:/var/usrlocal/lib/wootc:ro --entrypoint /usr/bin/python3 $IMAGE -c" "$CALLS"
    run grep -q '^chroot' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "the state-directory shape alone selects the image, as the chroot preparation does" {
    load_helper
    COMPOSEFS=0
    DEPLOY_ROOT="$WORK/mnt/verify/state/deploy/db5e7081"
    stage_helpers "$DEPLOY_ROOT"
    run target_python_imports wootc_boot_identity wootc_esp_transaction wootc_chain_source
    [ "$status" -eq 0 ]
    grep -q '^podman run' "$CALLS"
    run grep -q '^chroot' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "an ostree deployment is still chrooted into" {
    load_helper
    COMPOSEFS=0
    DEPLOY_ROOT="$WORK/mnt/verify/ostree/deploy/default/deploy/abc.0"
    stage_helpers "$DEPLOY_ROOT"
    mkdir -p "$DEPLOY_ROOT/usr/bin"
    ln -s "$PYTHON3" "$DEPLOY_ROOT/usr/bin/python3"
    run target_python_imports wootc_firstboot_evidence
    [ "$status" -eq 0 ]
    grep -q "^chroot $DEPLOY_ROOT /usr/bin/python3 -c" "$CALLS"
    run grep -q '^podman' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "an ostree root without Python still fails the check" {
    load_helper
    COMPOSEFS=0
    DEPLOY_ROOT="$WORK/mnt/verify/ostree/deploy/default/deploy/abc.0"
    stage_helpers "$DEPLOY_ROOT"
    status=0
    target_python_imports wootc_firstboot_evidence || status=$?
    [ "$status" -eq 127 ]
    grep -q 'No such file or directory' "$WORK/wootc-probe.err"
}

@test "a composefs image that cannot import the collector fails, with Python's error" {
    load_helper
    COMPOSEFS=1
    DEPLOY_ROOT="$WORK/mnt/verify/state/deploy/0f8ea28c"
    mkdir -p "$DEPLOY_ROOT/var/usrlocal/lib/wootc"
    run target_python_imports wootc_firstboot_evidence
    [ "$status" -ne 0 ]
    grep -q "No module named 'wootc_firstboot_evidence'" "$WORK/wootc-probe.err"
}

@test "an image run that cannot start fails the check and keeps podman's stderr" {
    load_helper
    COMPOSEFS=1
    DEPLOY_ROOT="$WORK/mnt/verify/state/deploy/0f8ea28c"
    stage_helpers "$DEPLOY_ROOT"
    PODMAN_FAIL="Error: netavark: nftables error" run target_python_imports wootc_firstboot_evidence
    [ "$status" -eq 125 ]
    grep -q 'netavark: nftables error' "$WORK/wootc-probe.err"
}

@test "both Python checks in deploy.sh go through target_python_imports" {
    # The helper's own ostree branch is the only chroot into python3 left.
    run grep -cE '^[^#]*chroot "\$DEPLOY_ROOT" /usr/bin/python3' "$DEPLOY"
    [ "$output" = 1 ]
    sed -n '/^target_python_imports() {/,/^}/p' "$DEPLOY" | grep -q 'chroot "$DEPLOY_ROOT" /usr/bin/python3'
    grep -q 'target_python_imports wootc_firstboot_evidence;' "$DEPLOY"
    grep -q 'target_python_imports wootc_boot_identity wootc_esp_transaction wootc_chain_source;' "$DEPLOY"
}
