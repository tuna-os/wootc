#!/usr/bin/env bats
#
# A composefs Phase 2 boots the deployer's Fedora kernel, which starts
# SELinux. On the Ubuntu and Debian images (grouper, flounder-sid) no policy
# loads, and `bootc status` stops with "Ensuring selinux install_t type: No
# label found in policy 'None' for /usr/bin/ostree" (runs 44769912580,
# 44770794387), so the first-boot record is never written. The deployer adds
# selinux=0 to the Phase-2 command line for an OS without SELinux.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    ROOT="$(mktemp -d)"
    eval "$(sed -n '/^phase2_lsm_karg() {/,/^}/p' "$DEPLOY")"
}

teardown() {
    rm -rf "$ROOT"
}

@test "an OS without /etc/selinux/config boots Phase 2 with selinux=0" {
    mkdir -p "$ROOT/etc"
    [ "$(phase2_lsm_karg "$ROOT")" = "selinux=0" ]
}

@test "an OS with SELINUX=disabled boots Phase 2 with selinux=0" {
    mkdir -p "$ROOT/etc/selinux"
    printf '# comment\nSELINUX=disabled\nSELINUXTYPE=targeted\n' > "$ROOT/etc/selinux/config"
    [ "$(phase2_lsm_karg "$ROOT")" = "selinux=0" ]
}

@test "an OS that uses SELinux keeps the kernel's default" {
    mkdir -p "$ROOT/etc/selinux"
    for mode in enforcing permissive; do
        printf '# SELINUX=disabled turns it off\nSELINUX=%s\nSELINUXTYPE=targeted\n' "$mode" > "$ROOT/etc/selinux/config"
        [ -z "$(phase2_lsm_karg "$ROOT")" ]
    done
}

@test "the karg joins PHASE2_KARGS before any Phase-2 boot entry is written" {
    local add first_use
    add=$(grep -n 'PHASE2_KARGS="$PHASE2_KARGS $PHASE2_LSM_KARG"' "$DEPLOY" | head -1 | cut -d: -f1)
    first_use=$(grep -n '\${PHASE2_KARGS}' "$DEPLOY" | head -1 | cut -d: -f1)
    [ -n "$add" ] && [ -n "$first_use" ]
    [ "$add" -lt "$first_use" ]
    grep -q 'PHASE2_LSM_KARG=$(phase2_lsm_karg "$DEPLOY_ROOT")' "$DEPLOY"
}

# The deployer kernel's modules exist only in the Phase-2 initrd; after
# switch-root the OS has its own kernel's tree. `bootc status` mounts
# root.disk's ESP and stopped with "Mounting /dev/loop0p1: No such device
# (os error 19)" on grouper (run 44781343011), whose initrd loader also
# reported every module "NOT FOUND" (it searched only /lib/modules).

# loader <modprobe exit status>: the initrd's load-modules.sh, console output
# on stdout, with modprobe/insmod/uname stubbed.
loader() {
    local bin="$ROOT/bin"
    mkdir -p "$bin"
    sed -n "/cat > \"\$OVL\/usr\/lib\/wootc\/load-modules.sh\" <<'SMODSH'/,/^SMODSH\$/p" "$DEPLOY" \
        | sed '1d;$d' | sed 's#/dev/console#/dev/stdout#' > "$ROOT/load-modules.sh"
    printf '#!/bin/sh\necho "modprobe $*" >>"%s"\nexit %s\n' "$ROOT/calls" "$1" > "$bin/modprobe"
    printf '#!/bin/sh\necho "insmod $*" >>"%s"\nexit 0\n' "$ROOT/calls" > "$bin/insmod"
    printf '#!/bin/sh\necho 7.3.4-test\n' > "$bin/uname"
    chmod +x "$bin"/*
    PATH="$bin:$PATH" sh "$ROOT/load-modules.sh"
}

@test "the composefs Phase-2 initrd modprobes fat, vfat and binfmt_misc" {
    run loader 0
    echo "$output"; cat "$ROOT/calls"
    [ "$status" -eq 0 ]
    local fat vfat
    fat=$(grep -nFx 'modprobe fat' "$ROOT/calls" | cut -d: -f1)
    vfat=$(grep -nFx 'modprobe vfat' "$ROOT/calls" | cut -d: -f1)
    [ -n "$fat" ] && [ -n "$vfat" ] && [ "$fat" -lt "$vfat" ]
    grep -qFx 'modprobe binfmt_misc' "$ROOT/calls"
    [[ "$output" == *"wootc: modprobe vfat"* ]]
    run grep -c '^insmod ' "$ROOT/calls"
    [ "$output" = 0 ]
}

@test "the Phase-2 module loader says which module it could not load" {
    run loader 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"wootc: module vfat NOT LOADED (kver 7.3.4-test, file: none)"* ]]
    [[ "$output" != *"NOT FOUND in /lib/modules"* ]]
}
