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
    grep -Fq 'export WOOTC_E2E_DISK2_SIZE="${WOOTC_E2E_DISK2_SIZE:-64G}"' "$E2E_RUNNER"
    grep -Fq "WOOTC_E2E_DISK2_SIZE: \${{ inputs.phase3 && '64G' || '' }}" "$REPO_ROOT/.github/workflows/e2e-hosted.yml"
    # The mount TARGET is a variable on purpose: dockur creates a disk2 whenever
    # /storage2 exists, defaulting to 64 GiB, and formatting it every run starved
    # swtpm's startup race and silently disabled TPM. So phase3 runs mount it at
    # /storage2 and everything else mounts it somewhere dockur ignores.
    grep -Fq 'phase3:${WOOTC_E2E_DISK2_MOUNT:-/storage2-unused}' "$REPO_ROOT/tests/e2e/compose.yml"
    grep -Fq 'export WOOTC_E2E_DISK2_MOUNT=/storage2' "$E2E_RUNNER"
    grep -Fq 'rm -f "$STORAGE_DIR/phase3/data2.qcow2"' "$E2E_RUNNER"
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

@test "Phase-3 dispatcher runs NTFS shrink verification before migration" {
    # The shrink check must appear BEFORE the destructive WOOTC_GN_ALLOW_DESTRUCTIVE gate
    # and after the blank-target recheck — ordering matters for safety.
    local shrink_line blank_line gate_line
    shrink_line=$(grep -nm1 'NTFS shrink verification' "$DISPATCH" | cut -d: -f1)
    blank_line=$(grep -nm1 'target is not blank' "$DISPATCH" | cut -d: -f1)
    gate_line=$(grep -nm1 'WOOTC_GN_ALLOW_DESTRUCTIVE=1' "$DISPATCH" | cut -d: -f1)
    [ -n "$shrink_line" ] && [ -n "$blank_line" ] && [ -n "$gate_line" ]
    [ "$blank_line" -lt "$shrink_line" ]
    [ "$shrink_line" -lt "$gate_line" ]
    grep -Fq 'wootc-go-native check' "$DISPATCH"
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

@test "migrate --dual-boot on loopback describes the graduate stages and touches nothing" {
    # The graduate plan lives under migrate --dual-boot (plain `plan` prints
    # the phase overview). Dry run must be read-only.
    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 WOOTC_GN_ESP=/dev/sda1 \
        run bash "$GN" migrate --dual-boot
    [ "$status" -eq 0 ]
    [[ "$output" == *"Graduate to native"* ]]
    [[ "$output" == *"NTFS shrink safety"* ]]
    [[ "$output" == *"Safe shrink default"* ]]
    [[ "$output" == *"Dry run only"* ]]
    refute_disk_touched
}

@test "migrate --dual-boot with shrink fixture shows available space and safe defaults" {
    local info_fixture="$TMP/ntfsresize-info.txt"
    cat >"$info_fixture" <<'NTFSINFO'
ntfsresize v2022.10.3 (libntfs-3g)
Device name        : /dev/sda2
NTFS volume version: 3.1
Cluster size       : 4096 bytes
Current volume size: 268435456000 bytes (268436 MB)
Current device size: 268435456512 bytes (268436 MB)
You might resize at 120000000000 bytes (120000 MB)
NTFSINFO
    export WOOTC_GN_NTRESIZE_INFO="$info_fixture"
    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 WOOTC_GN_ESP=/dev/sda1 \
        run bash "$GN" migrate --dual-boot
    [ "$status" -eq 0 ]
    [[ "$output" == *"NTFS shrink safety  : [ok]"* ]]
    [[ "$output" == *"GiB available"* ]]
    [[ "$output" == *"Safe shrink default"* ]]
    refute_disk_touched
}

@test "migrate --dual-boot with dirty NTFS fixture shows the dirty-volume diagnostic" {
    local info_fixture="$TMP/ntfsresize-dirty.txt"
    printf 'Volume is dirty.
You must run chkdsk /f on Windows.
' >"$info_fixture"
    export WOOTC_GN_NTRESIZE_INFO="$info_fixture"
    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 WOOTC_GN_ESP=/dev/sda1 \
        run bash "$GN" migrate --dual-boot
    [ "$status" -eq 0 ]
    [[ "$output" == *"NTFS shrink safety  : [dirty]"* ]]
    refute_disk_touched
}

@test "migrate --dual-boot with no-space NTFS fixture shows the nospace diagnostic" {
    local info_fixture="$TMP/ntfsresize-nospace.txt"
    cat >"$info_fixture" <<'NTFSINFO'
Current volume size: 100000000000 bytes
You might resize at 100000000000 bytes
NTFSINFO
    export WOOTC_GN_NTRESIZE_INFO="$info_fixture"
    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 WOOTC_GN_ESP=/dev/sda1 \
        run bash "$GN" migrate --dual-boot
    [ "$status" -eq 0 ]
    [[ "$output" == *"NTFS shrink safety  : [nospace]"* ]]
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
    # Without layout fixtures, the NTFS shrink check is skipped (not a hard gate).
    refute_disk_touched
}

@test "check verifies NTFS shrinkability when layout is discoverable" {
    local info_fixture="$TMP/ntfsresize-info.txt"
    cat >"$info_fixture" <<'NTFSINFO'
Current volume size: 268435456000 bytes
You might resize at 120000000000 bytes
NTFSINFO
    export WOOTC_GN_NTRESIZE_INFO="$info_fixture"
    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 WOOTC_GN_ESP=/dev/sda1 \
        run bash "$GN" check
    [[ "$output" == *"NTFS shrink safety"* ]]
    [[ "$output" == *"GiB available"* ]]
    refute_disk_touched
}

@test "check warns on dirty NTFS but does not hard-block" {
    local info_fixture="$TMP/ntfsresize-dirty.txt"
    printf 'Volume is dirty.\nYou must run chkdsk /f on Windows.\n' >"$info_fixture"
    export WOOTC_GN_NTRESIZE_INFO="$info_fixture"
    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 WOOTC_GN_ESP=/dev/sda1 \
        run bash "$GN" check
    # Dirty NTFS is a soft gate — check still passes (spare-disk graduate is available).
    [[ "$output" == *"[warn] NTFS shrink check"* ]]
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
    grep -Fq '"$P3_SNAPSHOT_SCRIPT" wootc-phase3-snapshot native' "$E2E_RUNNER"
    grep -Fq '/etc/wootc/native-target' "$REPO_ROOT/tests/e2e/phase3-snapshot.sh"
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
    echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert "shrink" in d, d'
    refute_disk_touched
}

@test "status --json with shrink fixture reports ntfsShrinkable gate and safeGib" {
    local info_fixture="$TMP/ntfsresize-info.txt"
    cat >"$info_fixture" <<'NTFSINFO'
Current volume size: 268435456000 bytes
You might resize at 120000000000 bytes
NTFSINFO
    export WOOTC_GN_NTRESIZE_INFO="$info_fixture"
    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_ROOT_SRC=/dev/nbd0p3 \
        WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 WOOTC_GN_ESP=/dev/sda1 \
        run bash "$GN" status
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["gates"]["ntfsShrinkable"], d; assert d["shrink"]["ok"], d; assert d["shrink"]["safeGib"] > 0, d'
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
    grep -Fq '\"user\": $guserjson' "$GN"
    grep -Fq 'guserjson=$(phase2_user_json "$guser" "$gfull" "$ghash")' "$GN"
    grep -qE '^[^#]*ghash=.*etc/shadow' "$GN"
    grep -qE '^[^#]*chown -R .*guser' "$GN"
    run bash -c 'source "$1"; phase2_user_json wootc "" "\$6\$salt\$hash"' _ "$GN"
    [ "$status" -eq 0 ]
    [ "$(jq -c . <<<"$output")" = '{"username":"wootc","password":"$6$salt$hash","groups":["wheel"]}' ]
}

@test "Phase-3 recipe carries the GECOS full name JSON-escaped, first subfield only" {
    # The GECOS name used to be pasted into the recipe raw: a quote or
    # backslash broke the JSON, and chfn's ",room,phone" subfields rode along
    # into the native account's name.
    heredoc=$(sed -n '/^    cat > "\$recipe" <<EOF$/,/^EOF$/p' "$GN" | sed '1d;$d')
    [ -n "$heredoc" ]
    gecos='Zoë "Zed" O'"'"'Brien-Åberg\ a1b2c3,Room 1,555,,'
    run env HEREDOC="$heredoc" bash -c 'source "$1"
        target=/dev/sdb filesystem=xfs img=ghcr.io/ublue-os/bluefin:stable
        ghost=wootc-test gsettings="" gflatpakjson="[]"
        guserjson=",
  \"user\": $(phase2_user_json wootc "$2" "\$6\$salt\$hash")"
        eval "cat <<EOF
$HEREDOC
EOF"' _ "$GN" "$gecos"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.user.fullname' <<<"$output")" = 'Zoë "Zed" O'"'"'Brien-Åberg\ a1b2c3' ]
    [ "$(jq -r '.user.password' <<<"$output")" = '$6$salt$hash' ]
    # The E2E seed, as useradd stored it, comes back byte for byte.
    run bash -c 'source "$1"; phase2_user_json wootc "$2" ""' _ "$GN" "Zoë O'Brien-Åberg 0a1b2c"
    [ "$(jq -r '.fullname' <<<"$output")" = "Zoë O'Brien-Åberg 0a1b2c" ]
    # A ':' or newline (useradd refuses both) never reaches the recipe.
    run bash -c 'source "$1"; phase2_user_json wootc "$2" ""' _ "$GN" $'Ann:\nLee'
    [ "$(jq -r '.fullname' <<<"$output")" = 'Ann Lee' ]
}

@test "Phase-3 installs the /run userdata probe for the confined guest agent" {
    # virt_qemu_ga_t cannot read user homes at all (run 20260723T0647 failed
    # the persistence gate on a file that was present). Proof must be
    # exported to /run at boot by a unit running unconfined.
    grep -q 'wootc-e2e-native-probe.service' "$GN"
    grep -q '/run/wootc-e2e-native-userdata' "$GN"
    grep -q 'multi-user.target.wants/wootc-e2e-native-probe.service' "$GN"
    # And it stays E2E-only: inside the dispatcher-gated block.
    local block
    block=$(awk '/^    if \[\[ -x \/var\/usrlocal\/libexec\/wootc-e2e-phase3-dispatch / { active=1 }
        active { print }
        active && /^    fi$/ { exit }' "$GN")
    [[ "$block" == *'e2e-native-probe.sh'* ]]
    [[ "$block" == *'multi-user.target.wants/wootc-e2e-native-probe.service'* ]]
}

@test "Phase-3 installs the /run root probe, ordered before the guest agent" {
    # The confined agent cannot search /sysroot/ostree (run 39007144179:
    # readlink -e failed for the composefs datadir), and the composefs image
    # mount is detached. The export must exist before the agent answers, and
    # the unit stays active so it runs once per boot.
    local block unit
    # Heredoc bodies are skipped: the probe script has its own "    fi".
    block=$(awk '/^    if \[\[ -x \/var\/usrlocal\/libexec\/wootc-e2e-phase3-dispatch / { active=1 }
        heredoc && $0 == heredoc { heredoc=""; next }
        heredoc { next }
        active { print }
        active && match($0, /<<.[A-Z]+.$/) { heredoc=substr($0, RSTART+3, RLENGTH-4) }
        active && /^    fi$/ { exit }' "$GN")
    [[ "$block" == *'e2e-native-root-probe.sh'* ]]
    [[ "$block" == *'multi-user.target.wants/wootc-e2e-native-root-probe.service'* ]]
    unit=$(awk '/wootc-e2e-native-root-probe.service" <<.UNIT.$/ { active=1; next }
        active && /^UNIT$/ { exit }
        active { print }' "$GN")
    [[ "$unit" == *'Before=qemu-guest-agent.service'* ]]
    [[ "$unit" == *'RemainAfterExit=yes'* ]]
    [[ "$unit" == *'ExecStart=/bin/bash /etc/wootc/e2e-native-root-probe.sh'* ]]
}

@test "Phase-3 labels the native /etc and /var with the target policy before the boot is scheduled" {
    # Probe 44843263310: on the enforcing native system 5943 paths under /etc
    # and /var/home kept the labels of offline useradd and of the /home copy
    # (passwd as etc_t, /var/home/linuxbrew as home_root_t).
    grep -qF 'setfiles -F -r "$dep" "$fc" "$dep/etc"' "$GN"
    grep -qF 'setfiles -F -r "$stateroot" "$fc" "$stateroot/var"' "$GN"
    local label boot rsync
    label=$(grep -nF 'setfiles -F -r "$dep"' "$GN" | head -1 | cut -d: -f1)
    rsync=$(grep -nF 'rsync -aHAX /home/ "$dest/"' "$GN" | head -1 | cut -d: -f1)
    boot=$(grep -n 'BootNext' "$GN" | awk -F: -v l="$label" '$1 > l { print $1; exit }')
    [ "$rsync" -lt "$label" ]
    [ -n "$boot" ]
    # A failed relabel stops before the native boot is scheduled.
    grep -q 'die "could not apply the native system.s SELinux labels' "$GN"
}

# relabel_block — the relabel step of graduate_to_disk_execute, with the
# label_repo_object_dirs helper it calls, for eval in a function that sets
# mnt and dep.
relabel_block() {
    awk '/^label_repo_object_dirs\(\) \{$/ { fn=1 }
        fn { print }
        fn && /^}$/ { fn=0 }
        /^    # Label everything graduation wrote/ { a=1 }
        a && /^    if \[\[ -n "\$dep" \]\]; then$/ { b=1 }
        b { print }
        b && /^    fi$/ { exit }' "$GN"
}

# relabel_fixture — a physical root at $mnt with a deployment $dep, its
# file_contexts $fc, an object store with one object, and stubs for setfiles,
# matchpathcon (CTX overrides the context it answers) and chcon.
relabel_fixture() {
    mnt="$TMP/phys"; dep="$mnt/ostree/deploy/default/deploy/abc.0"
    fc="$dep/etc/selinux/targeted/contexts/files/file_contexts"
    mkdir -p "$(dirname "$fc")" "$mnt/ostree/repo/objects/ab" "$mnt/ostree/repo/refs" \
        "$mnt/ostree/deploy/default/var/home" "$mnt/ostree/deploy/default/deploy/old.0" "$mnt/ostree/bootc"
    : >"$fc"; : >"$mnt/ostree/deploy/default/deploy/abc.origin"; : >"$mnt/ostree/repo/objects/ab/cdef.file"
    ln -s abc.0 "$mnt/ostree/deploy/default/deploy/current"
    printf '#!/bin/bash\necho "setfiles $*" >>"%s"\n[[ "$*" != *"${SETFILES_FAIL:-none}"* ]]\n' \
        "$CALLED" >"$STUBDIR/setfiles"
    cat >"$STUBDIR/matchpathcon" <<STUB
#!/bin/bash
echo "matchpathcon \$*" >>"$CALLED"
while [[ \$1 == -* ]]; do case \$1 in -m|-f) shift 2 ;; *) shift ;; esac; done
for p; do echo "\${CTX:-system_u:object_r:system_conf_t:s0}"; done
STUB
    printf '#!/bin/bash\necho "chcon $*" >>"%s"\n' "$CALLED" >"$STUBDIR/chcon"
    chmod +x "$STUBDIR/setfiles" "$STUBDIR/matchpathcon" "$STUBDIR/chcon"
}

@test "Phase-3 labels the physical root without reaching the deployments, the stateroot /var or the repo objects" {
    # Probe 44843263310: bootupd was denied getattr on an unlabeled
    # /sysroot/ostree/deploy. Repo objects are hardlinks of deployment files:
    # the repo's label must never reach them, nor the deployments' roots.
    local block mnt dep fc
    block=$(relabel_block)
    [[ "$block" == *setfiles* ]]
    relabel_fixture
    run env BLOCK="$block" bash -c 'die() { echo "DIE: $*"; exit 1; }; log() { echo "LOG: $*"; }
        f() { local mnt=$1 dep=$2; eval "$BLOCK"; }; f "$1" "$2"' _ "$mnt" "$dep"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^setfiles ' "$CALLED")" -eq 3 ]
    grep -qxF "setfiles -F -r $dep $fc $dep/etc" "$CALLED"
    grep -qxF "setfiles -F -r $mnt/ostree/deploy/default $fc $mnt/ostree/deploy/default/var" "$CALLED"
    grep -qxF "setfiles -F -r $mnt -e $dep -e $mnt/ostree/deploy/default/deploy/old.0 -e $mnt/ostree/deploy/default/var -e $mnt/ostree/repo/objects $fc $mnt" "$CALLED"
    # A failed physical-root relabel stops before the boot is scheduled.
    : >"$CALLED"
    run env BLOCK="$block" SETFILES_FAIL="-r $mnt -e" bash -c 'die() { echo "DIE: $*"; exit 1; }; log() { :; }
        f() { local mnt=$1 dep=$2; eval "$BLOCK"; }; f "$1" "$2"' _ "$mnt" "$dep"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE: could not apply the native system's SELinux labels"*"the physical root"* ]]
    grep -qx "umount $mnt" "$CALLED"
}

@test "Phase-3 labels /ostree/repo and its object directories, never the objects" {
    # Probe 44889931801: bootc 1.16.10 left /sysroot/ostree/repo unlabeled_t
    # (bootc-dev/bootc#2368) and graduation excluded the whole repo from its
    # relabel, so the enforcing native system denied searching it. The repo
    # and its metadata are labeled with the physical root; objects/ and its
    # fan-out directories by their own path; the object files keep the
    # labels of the deployment files they are hardlinks of.
    local block mnt dep fc ctx=system_u:object_r:system_conf_t:s0 line
    block=$(relabel_block)
    [[ "$block" == *'label_repo_object_dirs() {'* ]]
    relabel_fixture
    run env BLOCK="$block" bash -c 'die() { echo "DIE: $*"; exit 1; }; log() { echo "LOG: $*"; }
        f() { local mnt=$1 dep=$2; eval "$BLOCK"; }; f "$1" "$2"' _ "$mnt" "$dep"
    [ "$status" -eq 0 ]
    # The physical-root relabel reaches /ostree/repo and refs/, not objects/.
    line=$(grep "^setfiles -F -r $mnt -e " "$CALLED")
    [[ " $line " != *" -e $mnt/ostree/repo "* ]]
    [[ " $line " == *" -e $mnt/ostree/repo/objects "* ]]
    # The object directories are labeled by their path on the physical root.
    line=$(grep '^matchpathcon ' "$CALLED")
    [[ "$line" == "matchpathcon -N -n -m dir -f $fc "* ]]
    [ "$(printf '%s\n' ${line#"matchpathcon -N -n -m dir -f $fc "} | sort | tr '\n' ' ')" \
        = "/ostree/repo/objects /ostree/repo/objects/ab " ]
    [ "$(grep -c '^chcon ' "$CALLED")" -eq 2 ]
    grep -qxF "chcon -- $ctx $mnt/ostree/repo/objects" "$CALLED"
    grep -qxF "chcon -- $ctx $mnt/ostree/repo/objects/ab" "$CALLED"
    [ "$(grep -c 'cdef.file' "$CALLED")" -eq 0 ]
    # No context for an object directory stops before the boot is scheduled.
    : >"$CALLED"
    run env BLOCK="$block" CTX='<<none>>' bash -c 'die() { echo "DIE: $*"; exit 1; }; log() { :; }
        f() { local mnt=$1 dep=$2; eval "$BLOCK"; }; f "$1" "$2"' _ "$mnt" "$dep"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE: could not apply the native system's SELinux labels"*"the physical root"* ]]
    [ "$(grep -c '^chcon ' "$CALLED")" -eq 0 ]
    grep -qx "umount $mnt" "$CALLED"
}

@test "Phase-3 runs the post-boot health check from a boot unit that does not hold the boot" {
    # Probe 44833993709: run through the confined agent on the native system,
    # every systemctl call answered "Access denied". The check runs from
    # init's context instead. It waits for the boot itself, so a oneshot
    # (or ordering before the agent) would wait on its own start job.
    local block unit
    block=$(awk '/^    if \[\[ -x \/var\/usrlocal\/libexec\/wootc-e2e-phase3-dispatch / { active=1 }
        heredoc && $0 == heredoc { heredoc=""; next }
        heredoc { next }
        active { print }
        active && match($0, /<<.[A-Z]+.$/) { heredoc=substr($0, RSTART+3, RLENGTH-4) }
        active && /^    fi$/ { exit }' "$GN")
    [[ "$block" == *'"/run/wootc-$staged" "$etcroot/wootc/$staged"'* ]]
    [[ "$block" == *'e2e-native-health.sh'* ]]
    [[ "$block" == *'multi-user.target.wants/wootc-e2e-native-health.service'* ]]
    unit=$(awk '/wootc-e2e-native-health.service" <<.UNIT.$/ { active=1; next }
        active && /^UNIT$/ { exit }
        active { print }' "$GN")
    [[ "$unit" == *'Type=exec'* ]]
    [[ "$unit" == *'RuntimeMaxSec='* ]]
    [[ "$unit" != *'Before='* ]]
    [[ "$unit" == *'ExecStart=/bin/bash /etc/wootc/e2e-native-health.sh'* ]]
}

# native_health_probe <dir>: the HEALTHPROBE script with its /run, /etc and
# /proc paths moved under <dir>.
native_health_probe() {
    awk '/<<.HEALTHPROBE.$/ { active=1; next } active && /^HEALTHPROBE$/ { exit } active { print }' "$GN" \
        | sed -e "s#/run/wootc-e2e-native-health#$1/out#" \
              -e "s#/etc/wootc/#$1/etc/#g" \
              -e "s#/proc/sys/kernel/random/boot_id#$1/boot_id#g" > "$1/probe"
}

@test "native health probe exports the check's output, status and boot" {
    local d="$BATS_TEST_TMPDIR"
    mkdir -p "$d/etc"
    echo c49ec976-2f51-420f-a1a7-2cda006e6053 > "$d/boot_id"
    printf 'SCHEMA=1\nDISPLAY_MANAGER=gdm.service\n' > "$d/etc/e2e-phase3-health.baseline"
    printf '%s\n' 'echo "mode=$1"; printf "%s\n" "$2" | sed "s/^/baseline: /"; echo "FAIL: x"; exit 1' \
        > "$d/etc/e2e-phase3-health.sh"
    native_health_probe "$d"
    run bash "$d/probe"
    [ "$status" -eq 0 ]
    run cat "$d/out"
    [ "${lines[0]}" = HEALTH_SCHEMA=1 ]
    [ "${lines[1]}" = HEALTH_BOOT_ID=c49ec976-2f51-420f-a1a7-2cda006e6053 ]
    [ "${lines[2]}" = HEALTH_STATUS=1 ]
    [ "${lines[3]}" = mode=check ]
    [ "${lines[4]}" = "baseline: SCHEMA=1" ]
    [ "${lines[5]}" = "baseline: DISPLAY_MANAGER=gdm.service" ]
    [ "${lines[6]}" = "FAIL: x" ]
}

@test "native health probe without a staged check exports a failure, not silence" {
    local d="$BATS_TEST_TMPDIR"
    mkdir -p "$d/etc"
    echo c49ec976-2f51-420f-a1a7-2cda006e6053 > "$d/boot_id"
    native_health_probe "$d"
    run bash "$d/probe"
    [ "$status" -eq 0 ]
    run cat "$d/out"
    [ "${lines[2]}" = HEALTH_STATUS=127 ]
    [[ "${lines[3]}" == "no health check at $d/etc/e2e-phase3-health.sh"* ]]
}

@test "Phase-3 copies the QGA sysconfig without Phase 2's label, and not qemu-ga.conf" {
    # Run 39874539856: the native bluefin:stable system reached GDM but QGA
    # never answered. The deployer writes these configs unlabeled; cp -a
    # carried that onto the enforcing native system, and Fedora's qemu-ga
    # exits when it cannot read /etc/qemu/qemu-ga.conf.
    run grep -nE '^[^#]*cp -a [^ ]*qemu-ga' "$GN"
    [ "$status" -ne 0 ]
    run grep -nE '^[^#]*qemu-ga\.conf' "$GN"
    [ "$status" -ne 0 ]
    grep -qE '^[^#]*cp /etc/sysconfig/qemu-ga "\$etcroot/sysconfig/qemu-ga"' "$GN"
    unit=$(awk '/wootc-e2e-native-root-probe.service" <<.UNIT.$/ { active=1; next }
        active && /^UNIT$/ { exit }
        active { print }' "$GN")
    [[ "$unit" == *'TimeoutStartSec=60'* ]]
}

# ── Graduation scratch (run 44743470001) ─────────────────────────────────────
# bluefin:stable's 4.6 GiB of compressed layers filled a 30 GiB root.disk on
# every Phase-3 pull ("no space left on device" under /var/lib/containers).
# The pull and fisherman now run in an image-sized ext4 scratch next to
# root.disk on the Windows volume, as in the deployer.

# graduation_stubs <avail bytes on the Windows volume>: skopeo reports the
# bluefin:stable layer total (4,960,000,000 bytes = 4.62 GiB -> 21 GiB scratch).
graduation_stubs() {
    HOSTDIR="$TMP/host/wootc"; mkdir -p "$HOSTDIR/disks"
    printf '#!/bin/bash\necho "skopeo $*" >>"%s"\necho "2480000000 2480000000 "\n' "$CALLED" >"$STUBDIR/skopeo"
    printf '#!/bin/bash\necho "Avail"\necho "%s"\n' "$1" >"$STUBDIR/df"
    for tool in truncate mkfs.ext4; do
        printf '#!/bin/bash\necho "%s $*" >>"%s"\n' "$tool" "$CALLED" >"$STUBDIR/$tool"
    done
    # The scratch must exist while the install runs; the staged-install
    # child (GN_SELF) checks it.
    printf '#!/bin/bash\necho "truncate $*" >>"%s"\n: >"${@: -1}"\n' "$CALLED" >"$STUBDIR/truncate"
    printf '#!/bin/bash\necho "gn-self $* scratch-present=$([ -e "$2" ] && echo yes || echo no)" >>"%s"\n' "$CALLED" >"$STUBDIR/gn-self"
    chmod +x "$STUBDIR"/skopeo "$STUBDIR"/df "$STUBDIR"/truncate "$STUBDIR"/mkfs.ext4 "$STUBDIR"/gn-self
}

@test "Phase-3 scratch size matches the deployer's scratch formula" {
    local deploy="$REPO_ROOT/payload/deployer/deploy.sh" bytes ours theirs
    for bytes in "" 0 1073741824 4960000000 6760000000 12884901888; do
        ours=$(bash -c 'source "$1"; graduation_scratch_gib "$2"' _ "$GN" "$bytes")
        theirs=$(bash -c 'SCRATCH_MIN_GIB=20; eval "$(sed -n "/^scratch_need_gib() {/,/^}/p" "$1")"; scratch_need_gib "$2"' _ "$deploy" "$bytes")
        [ "$ours" = "$theirs" ] || { echo "bytes=$bytes go-native=$ours deployer=$theirs"; return 1; }
    done
    [ "$(bash -c 'source "$1"; graduation_scratch_gib 4960000000' _ "$GN")" = 21 ]
}

@test "Phase-3 stages the image in a scratch on the Windows volume, then deletes it" {
    graduation_stubs $(( 28 << 30 ))
    run bash -c 'source "$1"; PATH="$2:$PATH"; GN_SELF="$2/gn-self"; WOOTC_GN_HOST_DIR="$3" native_install_staged ghcr.io/projectbluefin/bluefin:stable /run/r.json' \
        _ "$GN" "$STUBDIR" "$HOSTDIR"
    echo "$output"; cat "$CALLED"
    [ "$status" -eq 0 ]
    grep -Fxq "truncate -s 21G $HOSTDIR/cache/native-scratch.img" "$CALLED"
    grep -Fxq "mkfs.ext4 -q -F $HOSTDIR/cache/native-scratch.img" "$CALLED"
    # A child process in the system's own mount namespace: bootc looks its
    # source image up with podman in PID 1's namespace (probe 44825571768).
    grep -Fxq "gn-self __staged-install $HOSTDIR/cache/native-scratch.img ghcr.io/projectbluefin/bluefin:stable /run/r.json scratch-present=yes" "$CALLED"
    run grep -n 'unshare' "$GN"
    [ "$status" -ne 0 ]
    [ ! -e "$HOSTDIR/cache/native-scratch.img" ]
}

@test "Phase-3 refuses before writing anything when the Windows volume cannot hold the scratch" {
    graduation_stubs $(( 15 << 30 ))
    run bash -c 'source "$1"; PATH="$2:$PATH"; WOOTC_GN_HOST_DIR="$3" native_install_staged ghcr.io/projectbluefin/bluefin:stable /run/r.json' \
        _ "$GN" "$STUBDIR" "$HOSTDIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"needs about 21 GiB of temporary space on the Windows drive"* ]]
    [[ "$output" == *"the drive has 15 GiB free"* ]]
    run grep -E '^(truncate|mkfs.ext4|gn-self) ' "$CALLED"
    [ "$status" -ne 0 ]
    [ ! -e "$HOSTDIR/cache/native-scratch.img" ]
}

@test "Phase-3 says it cannot read the free space instead of claiming 0 GiB free" {
    # Gate probe 44771739639 refused with "the drive has 0 GiB free"; an
    # empty or failed df produced the same words as a full drive.
    graduation_stubs 0
    printf '#!/bin/bash\necho "df: %s: No such file or directory" >&2\nexit 1\n' "$HOSTDIR" >"$STUBDIR/df"
    run bash -c 'source "$1"; PATH="$2:$PATH"; WOOTC_GN_HOST_DIR="$3" native_install_staged ghcr.io/projectbluefin/bluefin:stable /run/r.json' \
        _ "$GN" "$STUBDIR" "$HOSTDIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot read the free space of the Windows drive at $HOSTDIR: df: $HOSTDIR: No such file or directory"* ]]
    [[ "$output" != *"GiB free"* ]]
    run grep -E '^(truncate|mkfs.ext4|gn-self) ' "$CALLED"
    [ "$status" -ne 0 ]
}

@test "Phase-3 refusal names the drive totals and the largest files on it" {
    graduation_stubs $(( 15 << 30 ))
    printf '#!/bin/bash\nif [ "$1" = -h ]; then echo " Size Used Avail"; echo " 79G 64G 15G"; else echo Avail; echo %s; fi\n' $(( 15 << 30 )) >"$STUBDIR/df"
    dd if=/dev/zero of="$HOSTDIR/disks/root.disk" bs=1 count=0 seek=2G 2>/dev/null  # truncate is stubbed
    run bash -c 'source "$1"; PATH="$2:$PATH"; WOOTC_GN_HOST_DIR="$3" native_install_staged ghcr.io/projectbluefin/bluefin:stable /run/r.json' \
        _ "$GN" "$STUBDIR" "$HOSTDIR"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Windows drive at $HOSTDIR:  79G 64G 15G"* ]]
    [[ "$output" == *"largest files under $HOSTDIR: $HOSTDIR/disks/root.disk 2147483648 bytes;"* ]]
    [[ "$output" == *"the drive has 15 GiB free"* ]]
}

@test "Phase-3 staged install mounts the scratch over podman's storage before it pulls, and unmounts it" {
    for tool in mkdir chmod mount fisherman; do
        printf '#!/bin/bash\necho "%s $*" >>"%s"\n' "$tool" "$CALLED" >"$STUBDIR/$tool"
    done
    # Nothing is local in a fresh scratch: `podman image exists` fails.
    printf '#!/bin/bash\necho "podman $* TMPDIR=$TMPDIR" >>"%s"\n[ "$1 $2" != "image exists" ]\n' "$CALLED" >"$STUBDIR/podman"
    chmod +x "$STUBDIR"/mkdir "$STUBDIR"/chmod "$STUBDIR"/mount "$STUBDIR"/fisherman "$STUBDIR"/podman
    run bash -c 'source "$1"; PATH="$2:$PATH"; cmd_staged_install /h/wootc/cache/native-scratch.img img:tag /run/r.json' \
        _ "$GN" "$STUBDIR"
    echo "$output"; cat "$CALLED"
    [ "$status" -eq 0 ]
    # /var/tmp stays the session's own; podman stages blobs via TMPDIR.
    run grep -E '^mount .* /var/tmp$' "$CALLED"
    [ "$status" -ne 0 ]
    local want=(
        "mount -o loop /h/wootc/cache/native-scratch.img /var/fisherman-tmp"
        "mount --bind /var/fisherman-tmp/host-containers /var/lib/containers"
        "mount -t tmpfs tmpfs /run/containers"
        "mount -t tmpfs tmpfs /run/libpod"
        "podman pull img:tag TMPDIR=/var/fisherman-tmp/var-tmp"
        "fisherman /run/r.json"
        "umount -R /run/libpod"
        "umount -R /run/containers"
        "umount -R /var/lib/containers"
        "umount -R /var/fisherman-tmp"
    ) prev=0 line
    for w in "${want[@]}"; do
        line=$(grep -Fxn "$w" "$CALLED" | head -1 | cut -d: -f1)
        [ -n "$line" ] || { echo "missing: $w"; return 1; }
        [ "$line" -gt "$prev" ] || { echo "out of order: $w"; return 1; }
        prev=$line
    done
}

# host_layout <backing_file text> <root.disk bytes>: /sysroot on loop0p3, the
# loop's sysfs (16 MiB device) and a host mount holding wootc/disks/root.disk.
host_layout() {
    mkdir -p "$TMP/sys/block/loop0/loop" "$TMP/hostmnt/wootc/disks"
    printf '%s\n' "$1" >"$TMP/sys/block/loop0/loop/backing_file"
    printf '32768\n' >"$TMP/sys/block/loop0/size"
    head -c "$2" /dev/zero >"$TMP/hostmnt/wootc/disks/root.disk"
    printf '#!/bin/bash\n[ "${@: -1}" = /sysroot ] && echo /dev/loop0p3\n' >"$STUBDIR/findmnt"
    printf '#!/bin/bash\necho loop0\n' >"$STUBDIR/lsblk"
    chmod +x "$STUBDIR/findmnt" "$STUBDIR/lsblk"
}

find_host() {
    run bash -c 'source "$1"; PATH="$2:$PATH"; GN_SYSFS="$3/sys"; GN_HOST_MNT="$3/hostmnt"; host_wootc_dir' \
        _ "$GN" "$STUBDIR" "$TMP"
}

@test "Phase-3 finds the Windows volume from the root.disk loop backing file" {
    host_layout "$TMP/hostmnt/wootc/disks/root.disk" $(( 16 << 20 ))
    find_host
    [ "$status" -eq 0 ]
    [ "$output" = "$TMP/hostmnt/wootc" ]
}

@test "Phase-3 finds the Windows volume when the kernel reports the backing path from the volume root" {
    # Gate probe 44781443975 (bluefin): backing_file read "/wootc/disks/root.disk",
    # and `df /wootc` failed. The file is at the private host mount.
    host_layout /wootc/disks/root.disk $(( 16 << 20 ))
    find_host
    [ "$status" -eq 0 ]
    [ "$output" = "$TMP/hostmnt/wootc" ]
}

@test "Phase-3 does not take a same-named file of another size for root.disk" {
    host_layout /wootc/disks/root.disk $(( 8 << 20 ))
    find_host
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# ── Phase-3 progress (gate probe 44791710524: 15 minutes of one status line) ─

@test "Phase-3 logs the scratch and target-disk totals only when they move" {
    mkdir -p "$TMP/sys/block/sdb"
    echo "0 0 0 0 0 0 0 0" >"$TMP/sys/block/sdb/stat"
    printf '#!/bin/bash\necho Used\necho 1234M\n' >"$STUBDIR/df"; chmod +x "$STUBDIR/df"
    run bash -c 'source "$1"; PATH="$2:$PATH"; GN_SYSFS="$3"; GN_PROGRESS_SECS=0.1
        stage_progress /dev/sdb 2>"$4" & pid=$!
        sleep 1; echo "0 0 0 0 0 0 4096 0" >"$3/block/sdb/stat"; sleep 1
        kill "$pid"' _ "$GN" "$STUBDIR" "$TMP/sys" "$TMP/log"
    cat "$TMP/log"
    [ "$(grep -c 'progress: ' "$TMP/log")" -eq 2 ]
    grep -Fxq '[wootc-go-native] progress: scratch 1234M used, 0 MiB written to /dev/sdb' "$TMP/log"
    grep -Fxq '[wootc-go-native] progress: scratch 1234M used, 2 MiB written to /dev/sdb' "$TMP/log"
}

@test "Phase-3 staged install stops its progress log when it fails" {
    # A progress loop left running holds the dispatcher's output pipe open, and
    # the result file would never be written.
    for tool in mkdir chmod mount podman; do
        printf '#!/bin/bash\nexit 0\n' >"$STUBDIR/$tool"
    done
    printf '#!/bin/bash\nexit 1\n' >"$STUBDIR/fisherman"
    chmod +x "$STUBDIR"/mkdir "$STUBDIR"/chmod "$STUBDIR"/mount "$STUBDIR"/podman "$STUBDIR"/fisherman
    printf '{ "disk": "/dev/sdb" }\n' >"$TMP/r.json"
    run timeout 20 bash -c 'source "$1"; PATH="$2:$PATH"; cmd_staged_install /h/scratch.img img:tag "$3" 2>&1 | cat' \
        _ "$GN" "$STUBDIR" "$TMP/r.json"
    echo "$output"
    [ "$status" -ne 124 ]
    [[ "$output" == *"fisherman native install failed"* ]]
}

@test "Phase-3 dispatcher streams the migration output to the progress file" {
    local block
    block=$(sed -n '/^run_migration 2>&1 | while/,/^rc=\${PIPESTATUS\[0\]}$/p' "$DISPATCH")
    [ -n "$block" ]
    run bash -c 'PROGRESS=$1; TMP=$2
        run_migration() { echo one; printf two; return 7; }
        eval "$3"; echo "rc=$rc"' _ "$TMP/progress" "$TMP/result" "$block"
    [ "$output" = "rc=7" ]
    [ "$(cat "$TMP/result")" = "$(printf 'one\ntwo')" ]
    [ "$(wc -l <"$TMP/progress")" -eq 2 ]
    grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z one$' "$TMP/progress"
    grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z two$' "$TMP/progress"
}

@test "E2E bounds Phase 3 by progress, not a fixed count of polls" {
    run grep -F 'seq 1 180' "$E2E_RUNNER"
    [ "$status" -ne 0 ]
    # Probe 44807218628: 6-8 minute registry stalls, a 41-minute pull.
    grep -Fq 'P3_STALL_SECS=${WOOTC_E2E_P3_STALL_SECS:-900}' "$E2E_RUNNER"
    grep -Fq 'P3_MAX_SECS=${WOOTC_E2E_P3_MAX_SECS:-4500}' "$E2E_RUNNER"
    grep -Fq "stat -c %s /run/wootc-e2e-phase3.progress" "$E2E_RUNNER"
    grep -Fq 'rm -f /run/wootc-e2e-phase3.result /run/wootc-e2e-phase3.progress;' "$E2E_RUNNER"
    grep -Fq '> "$ARTIFACT_DIR/phase3-progress.log"' "$E2E_RUNNER"
}

@test "Phase-3 asks fisherman to validate the recipe before it pulls the image" {
    # Probe 44807218628 pulled for 41 minutes, then fisherman refused the
    # 40 GiB target (disk_too_small) at the start of the install.
    local validate_line staged_line
    validate_line=$(grep -nm1 '^[^#]*fisherman validate "\$recipe"' "$GN" | cut -d: -f1)
    staged_line=$(grep -nm1 '^    native_install_staged "\$img" "\$recipe"' "$GN" | cut -d: -f1)
    [ -n "$validate_line" ] && [ -n "$staged_line" ]
    [ "$validate_line" -lt "$staged_line" ]
    grep -A1 'fisherman validate "$recipe"' "$GN" | grep -Fq '|| die "fisherman refuses this install'
}
