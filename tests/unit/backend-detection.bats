#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="${DEPLOY:-$REPO_ROOT/payload/deployer/deploy.sh}"
    E2E="${E2E:-$REPO_ROOT/tests/e2e/run-e2e.sh}"
    PS1="${PS1:-$REPO_ROOT/tests/e2e/setup-wootc.ps1}"
}

@test "deployer accepts auto before image backend detection" {
    run awk '
        /case "\$BOOTLOADER" in/ { validation = NR; accepts_auto = ($0 ~ /grub2\|systemd\|auto/) }
        /if \[\[ "\$COMPOSEFS" == auto \|\| "\$BOOTLOADER" == auto \]\]/ { detection = NR }
        END { exit !(validation && accepts_auto && detection && validation < detection) }
    ' "$DEPLOY"
    [ "$status" -eq 0 ]
}

@test "E2E and Windows setup pass auto through by default" {
    run grep -F 'E2E_BOOTLOADER="${WOOTC_E2E_BOOTLOADER:-auto}"' "$E2E"
    [ "$status" -eq 0 ]

    run grep -F '[ValidateSet("grub2", "systemd", "auto")]' "$PS1"
    [ "$status" -eq 0 ]

    run grep -F '[string]$Bootloader = "auto"' "$PS1"
    [ "$status" -eq 0 ]
}

@test "backend detection falls back to safe defaults when the probe fails or is ambiguous" {
    # Contract since 95b0ab5/2d76cce: a hung or failed image probe must NOT
    # abort the deploy (that lost completed installs on flaky podman). It is
    # bounded by a timeout and falls back to ostree/grub2 + SEALED=1 with a
    # loud WARN; an unrecognized backend signal likewise defaults with a WARN.
    # The probe is still bounded by a timeout — but 30s was a timeout on a PULL,
    # not on an inspection (see the acquire-before-inspect test below), so the
    # contract is "bounded", not "bounded at 30".
    run grep -E 'if ! DETECT="\$\(timeout [0-9]+ podman run' "$DEPLOY"
    [ "$status" -eq 0 ]

    run grep -F 'falling back to default backend (ostree/grub2, ext4 sealed)' "$DEPLOY"
    [ "$status" -eq 0 ]

    run grep -F 'BACKEND=unknown' "$DEPLOY"
    [ "$status" -eq 0 ]

    # An image with neither bootupd-managed grub nor systemd-boot (Arch/Debian
    # bootc images ship no bootupd) must still deploy, not abort: ostree/grub2
    # plus --generic-image so bootc skips the bootupd requirement.
    run grep -F 'no bootupd and no systemd-boot' "$DEPLOY"
    [ "$status" -eq 0 ]

    run grep -F 'GENERIC_IMAGE=1' "$DEPLOY"
    [ "$status" -eq 0 ]
}

@test "current bootupd versioned EFI layout is recognized as ostree" {
    grep -Fq 'test -f /usr/lib/bootupd/updates/EFI.json' "$DEPLOY"
    grep -Fq 'find /usr/lib/efi/grub2 -type f -name grubx64.efi' "$DEPLOY"
    grep -Fq 'find /usr/lib/efi/shim -type f -name shimx64.efi' "$DEPLOY"
}

@test "ESP staging supports the current versioned shim and GRUB layout" {
    grep -Fq 'find "$DEPLOY_ROOT/usr/lib/efi/grub2"' "$DEPLOY"
    grep -Fq '*/EFI/$vendor_dir/shimx64.efi' "$DEPLOY"
    grep -Fq '*/EFI/$TARGET_VENDOR/mmx64.efi' "$DEPLOY"
    run grep -nE '^[^#]*dirname.*TARGET_GRUB' "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "ESP staging logs every selected source and fails closed" {
    grep -Fq 'ESP source kernel=${KERNEL_SRC:-missing}' "$DEPLOY"
    grep -Fq 'ESP source initramfs=${INITRD_SRC:-missing}' "$DEPLOY"
    grep -Fq 'ESP source shim=${TARGET_SHIM:-missing}' "$DEPLOY"
    grep -Fq 'ESP source grub=${TARGET_GRUB:-missing}' "$DEPLOY"
    local fail_line exit_line
    fail_line=$(grep -n 'Phase-2 ESP sync failed' "$DEPLOY" | tail -1 | cut -d: -f1)
    exit_line=$(awk -v start="$fail_line" 'NR > start && /exit 1/ { print NR; exit }' "$DEPLOY")
    [ -n "$fail_line" ] && [ -n "$exit_line" ]
    [ "$exit_line" -le $((fail_line + 8)) ]
}

@test "initramfs regen KVER comes from the module tree that owns vmlinuz" {
    # bluefin:lts ships TWO /usr/lib/modules trees: 6.12.0-225 (stripped
    # leftover, no vmlinuz) and 6.12.0-233 (bootable). `ls | head -1` picked
    # 225, dracut built a 225-module initramfs, the 233 kernel booted it, and
    # not one storage driver could load — 60s of "Present devices: none" and
    # an emergency shell, with no error anywhere. The pick must require
    # vmlinuz and take the highest such version.
    grep -Fq '[[ -f "$d/vmlinuz" ]] && basename "$d"' "$DEPLOY"
    run grep -nE 'KVER=\$\(ls [^)]*head -1\)' "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "deploy.sh uses no binaries absent from the initramfs closure" {
    # $(dirname ...) killed every deploy at t=33s under set -e — the
    # initramfs has no dirname (run 20260723T1331). Path math must use
    # parameter expansion; add to this list anything else the closure lacks.
    local dep="$REPO_ROOT/payload/deployer/deploy.sh"
    for missing in dirname; do
        run grep -nE "^[^#]*\\\$\\($missing " "$dep"
        [ "$status" -ne 0 ]
    done
}

@test "filesystem defaults: xfs unsealed, ext4 sealed (btrfs blocked on #35)" {
    # xfs is the product default; a sealed rootfs needs fs-verity, which xfs
    # lacks. ext4 is the PROVEN sealed fallback (29/29 green). btrfs also has
    # fs-verity but the ostree Phase-2 boot cannot mount it yet (#35), so it
    # stays opt-in via wootc.filesystem=. Both xfs.ko and btrfs.ko must be in
    # the initramfs — a typeless mount tried ext4 on xfs until GH 20260724.
    local dep="$REPO_ROOT/payload/deployer/deploy.sh"
    grep -q 'read_cmdline wootc.filesystem xfs' "$dep"
    grep -q 'FILESYSTEM=ext4' "$dep"
    grep -B9 'FILESYSTEM=ext4' "$dep" | grep -q 'ROOTFS_SEALED'
    grep -q -- '--add-drivers "xfs btrfs"' "$REPO_ROOT/payload/deployer/Containerfile"
    grep -q 'xfs.ko' "$REPO_ROOT/payload/deployer/Containerfile"
}

@test "dracut regen failures report dracut's own output" {
    # Bare stderr reaches only the serial console (harness never surfaces
    # it, CI truncates it): three regen failures reported nothing but
    # exit=1. The tail must go through err/log so it also lands in the
    # persistent deployer.log.
    local dep="$REPO_ROOT/payload/deployer/deploy.sh"
    grep -q 'dracut-regen.log' "$dep"
    grep -q 'err "  dracut: \$dline"' "$dep"
}

@test "the backend probe acquires the image before inspecting it" {
    # `podman run` on a non-local image PULLS it first. A multi-GB bootc image
    # cannot land inside the probe timeout, so the probe "failed" and fell back
    # to ostree/grub2 — silently deploying composefs-native images (dakota,
    # marlin) down the ostree path with none of the branch logic running. This
    # is why the composefs axis never moved.
    grep -q 'podman image exists "$IMAGE"' "$DEPLOY"
    grep -q 'podman pull "$IMAGE"' "$DEPLOY"
    # The pull must come BEFORE the probe.
    pull_line=$(grep -n 'podman pull "\$IMAGE"' "$DEPLOY" | head -1 | cut -d: -f1)
    probe_line=$(grep -n 'DETECT="\$(timeout' "$DEPLOY" | head -1 | cut -d: -f1)
    [ "$pull_line" -lt "$probe_line" ]
    # And the fallback must say loudly that composefs was not exercised.
    grep -q 'treat any resulting pass as untested for composefs' "$DEPLOY"
}

@test "verification does not assume the ostree 3-partition layout" {
    # A composefs-native install lays down ESP + root only, so root is p2 and p3
    # NEVER appears. Confirmed from the partition table the probe now prints:
    # /dev/loop1p1 = 2G EFI System, /dev/loop1p2 = 33G Linux root (run
    # 30234854504). Waiting for p3 warned about nodes that could not exist, and
    # the LUKS open targeted a device that was not there.
    run grep -c 'VERIFY_LOOP}p3' "$DEPLOY"
    [ "$output" -eq 0 ]
    grep -q '_verify_parts\[${#_verify_parts\[@\]}-1\]' "$DEPLOY"
}

@test "a composefs deployment root is not prepared as a chroot" {
    # It is a READ-ONLY image tree with no dev/proc/sys, and its branch performs
    # no chroot — but `mount --bind` ran first and set -e killed the deployer
    # silently at t=659s, after which the harness waited out 90 minutes.
    grep -q 'skipping chroot preparation' "$DEPLOY"
    grep -q 'DEPLOY_ROOT" == \*/state/deploy/\*' "$DEPLOY"
}

@test "an image with no NTFS driver fails the deploy, not Phase 2" {
    # "Relying on the image's own NTFS support" was never checked. On EL-family
    # images (no kernel ntfs3) a failed ntfs-3g injection still produced a full
    # deploy that CANNOT boot Phase 2: el10-gnome-win10pro spent 91 minutes to
    # reach "cannot mount host NTFS rw (no ntfs3, no ntfs-3g)" and an emergency
    # shell, when the evidence existed 80 minutes earlier.
    grep -q 'checking whether the image can mount NTFS on its own' "$DEPLOY"
    grep -q 'has NO NTFS driver' "$DEPLOY"
    grep -q 'Refusing to write an unbootable deployment' "$DEPLOY"
}

@test "Phase 2 never ships without an NTFS driver" {
    # Phase 2 mounts the Windows volume to reach root.disk. EL kernels have no
    # ntfs3, so the deployment needs ntfs-3g — and when the injection step fails
    # the old code logged a WARN and carried on, producing a deployment that
    # emergency-shelled with "no ntfs3, no ntfs-3g" 91 minutes later
    # (el10-gnome-win10pro, 20260727T082625Z).
    #
    # The deployer itself always ships ntfs-3g (its Containerfile), so use it.
    grep -q "Injected the deployer's own ntfs-3g" "$DEPLOY"
    grep -q 'command -v ntfs-3g' "$DEPLOY"
    # Its shared libraries must come too, or the installed binary cannot run.
    # Resolved through dso_closure, never `ldd` directly: ldd is a
    # glibc-common shell script that the deployer initramfs does not carry
    # (run 30707067821). See tests/unit/deployer-dso-closure.bats.
    grep -q 'dso_closure "\$_ntfs_src"' "$DEPLOY"
    # And with no driver available at all, refuse rather than ship it.
    grep -q 'no NTFS driver for Phase 2' "$DEPLOY"
    grep -q 'Refusing to finish a deployment that cannot boot' "$DEPLOY"
}

@test "no unbounded podman call in the deployer" {
    # An unbounded podman call is a SILENT HANG. dakota on himachal went quiet
    # at t=571s — right after the ntfs-3g injection's `podman rm -f` — and
    # produced nothing for the remaining 80 minutes; fisherman never started and
    # the run burned its whole budget with no output to say why. podman storage
    # can still be locked when the next command arrives, so every call must be
    # bounded and the deployer must keep talking.
    run bash -c "grep -nE '^[^#]*\\bpodman ' '$DEPLOY' | grep -v 'timeout '"
    [ -z "$output" ]
}

@test "a failed deploy puts its own log tail on the serial" {
    # log() writes to $PERSIST_LOG on the NTFS and err() to stderr, so on a
    # FAILED deploy — where Windows never returns to hand the file back — the
    # detailed record is stranded inside data.qcow2, unreadable without
    # libguestfs (not installed on our runners). dakota died having emitted two
    # serial lines total: its version and a cleanup warning.
    grep -q 'deployer log, last 60 lines' "$DEPLOY"
    # Only on failure, and only when there is something to show.
    grep -q '_rc" -ne 0 && -s "${PERSIST_LOG' "$DEPLOY"
    # The tail must go to stderr, which is what reaches the console.
    grep -A 4 'deployer log, last 60 lines' "$DEPLOY" | grep -q '>&2'
}

@test "the NTFS gate uses the same capability test as the injector" {
    # deploy.sh states from a real run that this check is NOT authoritative on a
    # weaker form: CONFIG_NTFS3=y kernels are built in, ship no .ko, mount fine,
    # and "making these failures fatal broke deploys that worked". The gate must
    # therefore test exactly what ensure_ntfs_support tests — including the
    # CONFIG_NTFS3_FS grep — or it will refuse deploys that work.
    run grep -c 'CONFIG_NTFS3_FS=\[ym\]' "$DEPLOY"
    [ "$output" -ge 2 ]
}

@test "ntfs-3g injection acquires the image before running dnf in it" {
    # `podman run` on a non-local image pulls it first; a multi-GB bootc image
    # cannot pull AND dnf-install inside the old 150s, so injection failed on
    # every cold cache while blaming "(network/repo?)".
    grep -q 'ntfs-3g injection: pulling' "$DEPLOY"
    grep -q 'the injection below will fail for that reason, not a repo one' "$DEPLOY"
}

@test "an image without an NTFS driver is not refused when the deployer has one" {
    # Both Phase-2 paths already take ntfs-3g from the DEPLOYER when the image
    # lacks it: composefs via the early cpio, ostree via the NTFS_BINS fallback.
    # Refusing on the image alone blocked dakota on every runner whose initramfs
    # cannot reach EPEL/CRB — i.e. both self-hosted boxes.
    grep -q "Phase 2 will carry the DEPLOYER's ntfs-3g instead" "$DEPLOY"
    # The deployer-capability arm must sit between "image has one" and the refusal.
    img_line=$(grep -n 'image provides its own NTFS driver' "$DEPLOY" | head -1 | cut -d: -f1)
    dep_line=$(grep -n "Phase 2 will carry the DEPLOYER's ntfs-3g" "$DEPLOY" | head -1 | cut -d: -f1)
    fail_line=$(grep -n 'has NO NTFS driver' "$DEPLOY" | head -1 | cut -d: -f1)
    [ "$img_line" -lt "$dep_line" ]
    [ "$dep_line" -lt "$fail_line" ]
}

@test "no assignment in the deployer aborts on a non-matching grep or empty ls" {
    # Under `set -o pipefail` a failing ls/grep fails its pipeline, and as the
    # last command of an `||` list that aborts the deployer under set -e with NO
    # message. dakota died exactly there: the log ends at "skipping chroot
    # preparation" and the next line is the exit-1 post-mortem.
    #
    # A composefs deployment's /usr/lib/modules is empty (content lives in the
    # .ostree.cfs), and `grep -c` exits 1 on ZERO matches — so each site aborted
    # precisely in the case it existed to measure.
    run awk '/^[^#]*[A-Za-z_]+=\$\(/{buf=$0; while (buf !~ /\)$/ && (getline nxt)>0) buf=buf" "nxt; if (buf ~ /\| *(grep|ls|sort|awk)/ && buf !~ /\|\| true/) print}' "$DEPLOY"
    [ -z "$output" ]
    # And the KVER fallback specifically must tolerate an empty module tree.
    grep -q 'usr/lib/modules" 2>/dev/null | sort -V | tail -1 || true' "$DEPLOY"
}

@test "teardown never turns a successful deploy into a failure" {
    # The composefs path SKIPS the dev/proc/sys binds (read-only tree, no
    # chroot), so an unconditional umount fails there — and umount's exit 32
    # became the deployer's exit status under set -e, killing it immediately
    # after "[PASS] Phase-2 setup completed with no problems". The deploy had
    # succeeded; the teardown reported a dead deployer and Phase 2 never got its
    # reboot (himachal 20260727T124314Z).
    grep -q 'mountpoint -q "\$DEPLOY_ROOT/\$fs" 2>/dev/null && umount' "$DEPLOY"
    # No bare umount may abort the script.
    run grep -nE '^\s+umount [^|]*$' "$DEPLOY"
    [ -z "$output" ]
}

@test "the deployer names the command that aborts it" {
    # set -e is silent, and the "last 60 lines" dump shows only the last
    # SUCCESSFUL log line — so a failing command that logs nothing is
    # invisible. bluefin-dakota-win11pro (run 30267737413) exited 32 with its
    # final line "skipping dracut regen", leaving the actual failure
    # unlocatable after a 60-minute run.
    grep -q 'wootc_report_abort' "$DEPLOY"
    grep -q "trap 'wootc_report_abort" "$DEPLOY"
    grep -q 'ABORT: line' "$DEPLOY"
    # fail+exit sites already report; the trap must stay quiet for them.
    grep -q 'case "$cmd" in exit\*) return 0 ;; esac' "$DEPLOY"
}
