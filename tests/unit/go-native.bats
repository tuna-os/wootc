#!/usr/bin/env bats
# go-native.bats — data-safety invariants for wootc-go-native (Phase 3).
#
# A bug here repartitions a real disk, so these tests pin the guards that must
# NEVER silently regress. All black-box: the script is invoked as a subprocess
# with its baked-in WOOTC_GN_* fixture hooks — no VM, no real disks, no edits
# to the script. The destructive paths are proven inert with PATH stubs: every
# tool that could touch a disk (bootc, podman, sfdisk, ntfsresize, mkfs.xfs,
# efibootmgr, mount) is replaced by a stub that records its invocation. We then
# assert no DESTRUCTIVE invocation occurred — a stronger claim than asserting
# the plan text printed, and more accurate than "nothing was called at all"
# (a dry run legitimately runs read-only probes like `bootc status --json`).
#
# Two traps this suite has already fallen into, both now guarded:
#   * stubs on a noexec tmpdir never execute, so every assertion passes
#     vacuously — setup() proves the stubs can run before trusting them;
#   * treating any tool call as destructive flags harmless read-only probes.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    GN="$REPO_ROOT/payload/migration/wootc-go-native"
    E2E_RUNNER="$REPO_ROOT/tests/e2e/run-e2e.sh"
    DISPATCH="$REPO_ROOT/payload/migration/wootc-e2e-phase3-dispatch"
    TMP="$BATS_TEST_TMPDIR"

    # PATH stub jail: any disk-touching tool records its invocation in $CALLED.
    # The stubs MUST be executable. On a host with a noexec /tmp (common, and
    # true of this repo's dev box) BATS_TEST_TMPDIR cannot execute them — the
    # stubs silently never run, nothing is recorded, and every "no disk was
    # touched" assertion below passes VACUOUSLY. That is exactly what happened:
    # these tests were green locally and only CI (with an exec /tmp) caught it.
    # So: pick an exec-capable dir and PROVE it before trusting the assertions.
    STUBDIR="$TMP/stubs"; mkdir -p "$STUBDIR"
    printf '#!/bin/bash\ntrue\n' >"$STUBDIR/.probe"; chmod +x "$STUBDIR/.probe"
    if ! "$STUBDIR/.probe" 2>/dev/null; then
        STUBDIR="$HOME/.cache/wootc-bats-stubs.$$"; mkdir -p "$STUBDIR"
        printf '#!/bin/bash\ntrue\n' >"$STUBDIR/.probe"; chmod +x "$STUBDIR/.probe"
        "$STUBDIR/.probe" 2>/dev/null || {
            echo "FATAL: cannot create executable stubs — assertions would be vacuous" >&2
            return 1
        }
    fi
    CALLED="$TMP/called"
    for tool in bootc podman sfdisk ntfsresize mkfs.xfs efibootmgr mount umount \
                growpart xfs_growfs bootupctl rsync; do
        cat >"$STUBDIR/$tool" <<STUB
#!/bin/bash
echo "$tool \$*" >>"$CALLED"
exit 0
STUB
        chmod +x "$STUBDIR/$tool"
    done
    export PATH="$STUBDIR:$PATH"

    # Default fixtures: on loopback, no host conf, empty home (no converted dirs).
    export WOOTC_GN_HOSTCONF="$TMP/nonexistent.conf"
    export WOOTC_GN_HOME="$TMP/home"; mkdir -p "$WOOTC_GN_HOME/.config/wootc"
}

@test "E2E invokes go-native by absolute path under QGA's minimal PATH" {
    local n
    # /var/usrlocal, not /usr/local: on composefs-SEALED images (bluefin:lts)
    # /usr/local is a REAL directory inside the sealed /usr, so deploy-time
    # writes through it are invisible at runtime; /var/usrlocal is the
    # stateroot var that IS mounted. Traditional images keep both equivalent
    # via the /usr/local -> ../var/usrlocal symlink.
    n=$(grep -c '/var/usrlocal/bin/wootc-go-native' "$E2E_RUNNER")
    [ "$n" -eq 1 ]
    run grep -nE "qga_call.*|'[^']*wootc-go-native|\"[^\"]*wootc-go-native" "$E2E_RUNNER"
    [[ "$output" != *"'wootc-go-native status"* ]]
    [[ "$output" != *" wootc-go-native migrate"* ]]
}

@test "go-native supplies sbin paths for GUI and QGA service environments" {
    grep -Fq 'export PATH="/var/usrlocal/sbin:/var/usrlocal/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"' "$GN"
}

@test "--phase3 provisions its dedicated blank target and handles none found" {
    grep -Fq 'export WOOTC_E2E_DISK2_SIZE="${WOOTC_E2E_DISK2_SIZE:-40G}"' "$E2E_RUNNER"
    grep -Fq -- '- ./storage/phase3:/storage2' "$REPO_ROOT/tests/e2e/compose.yml"
    grep -Fq 'rm -f storage/phase3/data2.qcow2' "$E2E_RUNNER"
    grep -Fq 'QEMU has no dedicated /storage2/data2.qcow2 target' "$E2E_RUNNER"
    grep -A2 'P3_TARGET=$(qga_call' "$E2E_RUNNER" | grep -q '|| true)'
    grep -q 'Phase 3: no BLANK spare disk found' "$E2E_RUNNER"
}

@test "Phase-3 QGA uses the request-gated systemd boundary" {
    grep -Fq ': > "$OEM_PAYLOAD/e2e-phase3"' "$E2E_RUNNER"
    grep -Fq '/run/wootc-e2e-phase3.request' "$E2E_RUNNER"
    grep -Fq '/run/wootc-e2e-phase3.result' "$E2E_RUNNER"
    # Since b653360 the bridge units are installed unconditionally (the marker
    # gate in deploy.sh aborted installs); the security boundary is the
    # /run request file, creatable only by root/qemu-ga, plus the dispatcher's
    # own blank-target recheck. deploy.sh must install AND wire the path unit.
    grep -Fq 'wootc-e2e-phase3-dispatch' "$REPO_ROOT/payload/deployer/deploy.sh"
    grep -Fq 'multi-user.target.wants/wootc-e2e-phase3.path' "$REPO_ROOT/payload/deployer/deploy.sh"
    grep -Fq 'WantedBy=multi-user.target' "$REPO_ROOT/payload/migration/wootc-e2e-phase3.path"
}

@test "Phase-3 dispatcher rechecks blank target before destructive gate" {
    local blank_line gate_line result_line
    blank_line=$(grep -nm1 'target is not blank' "$DISPATCH" | cut -d: -f1)
    gate_line=$(grep -nm1 'WOOTC_GN_ALLOW_DESTRUCTIVE=1' "$DISPATCH" | cut -d: -f1)
    result_line=$(grep -nm1 'mv -f "\$TMP" "\$RESULT"' "$DISPATCH" | cut -d: -f1)
    [ -n "$blank_line" ] && [ -n "$gate_line" ] && [ -n "$result_line" ]
    [ "$blank_line" -lt "$gate_line" ]
    [ "$gate_line" -lt "$result_line" ]
    grep -Fq 'echo "EXIT=$rc" >> "$TMP"' "$DISPATCH"
}

# Assert no DESTRUCTIVE disk operation happened. Read-only probes are fine and
# expected in a dry run — `bootc status --json` is how the plan discovers the
# local image ref, and lsblk/blkid inspect layout. Only writes must never occur.
refute_disk_touched() {
    [[ -e "$CALLED" ]] || return 0
    local bad
    bad=$(grep -aEi 'bootc +install|sfdisk|mkfs|wipefs|growpart|xfs_growfs|ntfsresize|efibootmgr +-[cB]|^dd ' "$CALLED" || true)
    if [[ -n "$bad" ]]; then
        echo "expected NO destructive disk op, but got:"; echo "$bad"
        return 1
    fi
}

teardown() {
    [[ "$STUBDIR" == "$HOME/.cache/"* ]] && rm -rf "$STUBDIR"
    return 0
}

# ── plan / check are always safe ────────────────────────────────────────────

@test "plan on loopback describes the graduate stages and touches nothing" {
    WOOTC_GN_FORCE_LOOP=1 run bash "$GN" plan
    [ "$status" -eq 0 ]
    [[ "$output" == *"Still on Windows NTFS  : yes"* ]]
    [[ "$output" == *"Graduate root to native"* ]]
    [[ "$output" == *"Remove Windows"* ]]
    refute_disk_touched
}

@test "plan when already native says nothing to graduate" {
    WOOTC_GN_FORCE_LOOP=0 WOOTC_GN_ROOT_SRC=/dev/sda3 run bash "$GN" plan
    [ "$status" -eq 0 ]
    [[ "$output" == *"already runs from a native Linux partition"* ]]
    refute_disk_touched
}

@test "check reports loopback + counts converted folders, never touches disk" {
    touch "$WOOTC_GN_HOME/.config/wootc/converted-Documents"
    touch "$WOOTC_GN_HOME/.config/wootc/converted-Pictures"
    WOOTC_GN_FORCE_LOOP=1 run bash "$GN" check
    [[ "$output" == *"loopback"* ]]
    [[ "$output" == *"2 user folder(s) already native"* ]]
    refute_disk_touched
}

# ── the safety gates: these must REFUSE (non-zero, no disk touched) ──────────

@test "migrate --reclaim REFUSES while still on loopback" {
    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 \
        run bash "$GN" migrate --reclaim --execute
    [ "$status" -ne 0 ]
    [[ "$output" == *"still running from root.disk"* ]]
    refute_disk_touched
}

@test "migrate --reclaim REFUSES when no folders are verified native" {
    # native now, but zero converted-* markers → data may still be Windows-only
    WOOTC_GN_FORCE_LOOP=0 WOOTC_GN_ROOT_SRC=/dev/sda3 \
        WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 \
        run bash "$GN" migrate --reclaim --execute
    [ "$status" -ne 0 ]
    [[ "$output" == *"no folders verified native"* ]]
    refute_disk_touched
}

@test "migrate --execute REFUSES without WOOTC_GN_ALLOW_DESTRUCTIVE=1" {
    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 \
        run bash "$GN" migrate --dual-boot --execute
    [ "$status" -ne 0 ]
    [[ "$output" == *"WOOTC_GN_ALLOW_DESTRUCTIVE=1"* ]]
    refute_disk_touched
}

@test "migrate with no mode REFUSES" {
    run bash "$GN" migrate
    [ "$status" -ne 0 ]
    [[ "$output" == *"choose --dual-boot"* ]]
    refute_disk_touched
}

# ── dry-run: prints the plan but must touch NOTHING ─────────────────────────

@test "migrate --dual-boot (no --execute) is a dry run that touches no disk" {
    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 WOOTC_GN_ESP=/dev/sda1 \
        run bash "$GN" migrate --dual-boot
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY RUN"* ]]
    [[ "$output" == *"Re-run with --execute"* ]]
    refute_disk_touched
}

@test "Phase-3 plan uses recorded registry origin, not deployer-local derived tag" {
    local conf="$TMP/host-esp.conf"
    printf 'HOST_ESP_UUID=TEST\nSOURCE_IMAGE_REF=ghcr.io/ublue-os/bluefin:latest\n' > "$conf"
    WOOTC_GN_HOSTCONF="$conf" WOOTC_GN_FORCE_LOOP=1 \
        WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 WOOTC_GN_ESP=/dev/sda1 \
        run bash "$GN" migrate --dual-boot
    [ "$status" -eq 0 ]
    [[ "$output" == *"containers-storage:ghcr.io/ublue-os/bluefin:latest"* ]]
    [[ "$output" != *"wootc-ntfs-injected"* ]]
    refute_disk_touched
}

@test "Phase-3 native install supplies the deployer-selected filesystem" {
    # Since 5b30210 the native install goes through fisherman, not a direct
    # bootc install to-disk: the recipe must carry the filesystem the deployer
    # recorded at deploy time (SOURCE_FILESYSTEM in host-esp.conf).
    grep -Fq '"filesystem": "$filesystem",' "$GN"
    grep -Fq 'SOURCE_FILESYSTEM=\K' "$GN"
    grep -Fq 'fisherman "$recipe"' "$GN"
    grep -Fq 'SOURCE_FILESYSTEM=%s' "$REPO_ROOT/payload/deployer/deploy.sh"
}

@test "Phase-3 home migration selects a partition, never the whole target disk" {
    grep -Fq "awk '\$3 == \"part\" { print \$1, \$2 }'" "$GN"
    grep -Fq 'native install produced no root partition' "$GN"
}

@test "Phase-3 schedules and positively verifies the native boot" {
    # fisherman creates the UEFI entry; go-native must find it by the target
    # ESP's PARTUUID (an observable), never by label — the label grep missed
    # fisherman's entry and the trusting fallback left BootOrder on Windows
    # (run 20260723T0215). No schedulable entry = hard failure, not a shrug.
    grep -Fq 'blkid -s PARTUUID -o value "$esp_part"' "$GN"
    grep -Fq 'efibootmgr -n "$bootnum"' "$GN"
    grep -q 'refusing to claim success without a schedulable native boot' "$GN"
    run grep -nE '^[^#]*"Graduate complete\. Reboot' "$GN"
    [ "$status" -ne 0 ]
    grep -Fq 'Phase 3 native system booted from the graduated install (non-loopback)' "$E2E_RUNNER"
    grep -Fq '/etc/wootc/native-target' "$E2E_RUNNER"
}

@test "migrate --reclaim dry run (native + converted) prints IRREVERSIBLE plan, no disk touched" {
    touch "$WOOTC_GN_HOME/.config/wootc/converted-Documents"
    WOOTC_GN_FORCE_LOOP=0 WOOTC_GN_ROOT_SRC=/dev/sda3 \
        WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 \
        run bash "$GN" migrate --reclaim
    [ "$status" -eq 0 ]
    [[ "$output" == *"IRREVERSIBLE"* ]]
    refute_disk_touched
}

# ── layout discovery failure is a clean refusal, not a crash ────────────────

@test "migrate REFUSES when the Windows disk cannot be located" {
    # no host conf, no WOOTC_GN_DISK/NTFS → discover_layout fails
    WOOTC_GN_FORCE_LOOP=1 run bash "$GN" migrate --dual-boot
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not locate the Windows disk"* ]]
    refute_disk_touched
}

# ── to-disk guard: never install onto the Windows disk itself ───────────────
# graduate_to_disk_execute checks `-b $target` before `target != $DISK`, so the
# target must be a real block device to reach the guard. Use a loop device.

# ── status --json (drives the Phase-3 GUI) ──────────────────────────────────

@test "status --json on loopback: canGraduate true, canReclaim false, touches nothing" {
    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_ROOT_SRC=/dev/nbd0p3 run bash "$GN" status
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["onLoopback"] and d["canGraduate"] and not d["canReclaim"], d'
    refute_disk_touched
}

@test "status --json native + converted folders: canReclaim true, folders listed" {
    touch "$WOOTC_GN_HOME/.config/wootc/converted-Documents"
    WOOTC_GN_FORCE_LOOP=0 WOOTC_GN_ROOT_SRC=/dev/sda3 run bash "$GN" status
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert not d["onLoopback"] and d["canReclaim"] and d["convertedFolders"]==["Documents"] and d["gates"]["dataIsNative"], d'
    refute_disk_touched
}

@test "status --json native but NO converted folders: canReclaim false (data-safety gate)" {
    WOOTC_GN_FORCE_LOOP=0 WOOTC_GN_ROOT_SRC=/dev/sda3 run bash "$GN" status
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert not d["canReclaim"] and not d["gates"]["dataIsNative"], d'
}

@test "migrate --to-disk REFUSES to install onto the Windows disk" {
    if [[ $EUID -ne 0 ]] && ! command -v sudo >/dev/null; then
        skip "needs root/sudo for losetup"
    fi
    local img="$TMP/win.img" loopdev
    truncate -s 16M "$img"
    loopdev=$(losetup --show -f "$img" 2>/dev/null) || sudo losetup --show -f "$img" 2>/dev/null || skip "losetup unavailable"
    [ -n "$loopdev" ] || skip "no loop device"

    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK="$loopdev" WOOTC_GN_NTFS="${loopdev}p2" WOOTC_GN_ESP="${loopdev}p1" \
    WOOTC_GN_ALLOW_DESTRUCTIVE=1 \
        run bash "$GN" migrate --to-disk "$loopdev" --execute

    losetup -d "$loopdev" 2>/dev/null || sudo losetup -d "$loopdev" 2>/dev/null || true
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to install onto the Windows disk"* ]]
    refute_disk_touched
}

@test "Phase-3 install uses fisherman podman-run mode with the origin image" {
    # The one bootc invocation proven against every supported image is the
    # deployer's own: fisherman podman-run mode (recipe image set), bootc
    # running INSIDE the image container. Both direct-mode variants failed
    # live on bluefin:lts (no --source-imgref: "must be executed inside a
    # podman container"; containers-storage transport: "Multiple commit
    # objects found" on sealed/chunked images).
    grep -Fq '"image": "$img",' "$GN"
    run grep -n '"targetImgref"' "$GN"
    [ "$status" -ne 0 ]
    grep -Fq 'podman image exists "$img"' "$GN"
    grep -Fq 'podman pull "$img"' "$GN"
    # The pull must come BEFORE fisherman runs.
    local pull_line fisherman_line
    pull_line=$(grep -nm1 'podman pull "\$img"' "$GN" | cut -d: -f1)
    fisherman_line=$(grep -nm1 'fisherman "\$recipe"' "$GN" | cut -d: -f1)
    [ -n "$pull_line" ] && [ -n "$fisherman_line" ]
    [ "$pull_line" -lt "$fisherman_line" ]
}

@test "Phase-3 post-install /etc writes target the deployment etc, not sysroot etc" {
    # On an ostree target $mnt/etc is the SYSROOT etc, which the booted
    # deployment never reads — native-target, qemu-ga configs, and the QGA
    # wants link all silently vanished there (run 20260723T0320: native boot
    # healthy, guest-exec still blacklisted, harness called it dead).
    grep -Fq 'etcroot="$mnt/etc"' "$GN"
    grep -Fq '[[ -n "$dep" ]] && etcroot="$dep/etc"' "$GN"
    grep -Fq 'printf '"'"'%s\n'"'"' "$target" > "$etcroot/wootc/native-target"' "$GN"
    # No stragglers writing to the sysroot etc.
    run grep -nE '^[^#]*"\$mnt/etc/' "$GN"
    [ "$status" -ne 0 ]
}

@test "Phase-3 recipe mirrors the running account into the native install" {
    # Run 20260723T0647: the minimal recipe had no user — the native system
    # held the rsync'd home with no passwd entry, no tmpfiles home pin, and
    # foreign labels. The account must ride the recipe (fisherman CreateUser)
    # with the crypt hash copied verbatim, and the migrated home chowned to
    # the user (rsync preserves the fuse binds' root:root ownership).
    grep -Fq '\"user\": {' "$GN"
    grep -Fq '\"username\": \"$guser\"' "$GN"
    grep -qE '^[^#]*ghash=.*etc/shadow' "$GN"
    grep -qE '^[^#]*chown -R .*guser' "$GN"
}

@test "Phase-3 installs the /run userdata probe for the confined guest agent" {
    # virt_qemu_ga_t cannot read user homes at all (run 20260723T0647 failed
    # the persistence gate on a file that was present). Proof must be
    # exported to /run at boot by a unit running unconfined.
    grep -q 'wootc-e2e-native-probe.service' "$GN"
    grep -q '/run/wootc-e2e-native-userdata' "$GN"
    grep -q 'multi-user.target.wants/wootc-e2e-native-probe.service' "$GN"
    # And it stays E2E-only: inside the dispatcher-gated block.
    grep -B40 'wootc-e2e-native-probe.service' "$GN" | grep -q 'wootc-e2e-phase3-dispatch'
}
