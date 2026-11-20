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
# (os error 19)" on grouper (run 44781343011). The initrd loads fat and vfat.
@test "the composefs Phase-2 initrd loads fat before vfat" {
    local script list
    script=$(sed -n "/cat > \"\$OVL\/usr\/lib\/wootc\/load-modules.sh\" <<'SMODSH'/,/^SMODSH\$/p" "$DEPLOY")
    list=$(grep -m1 '^for _mod in ' <<<"$script")
    [[ "$list" =~ \ fat\ vfat\; ]]
}
