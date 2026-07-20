#!/usr/bin/env bats
# pick-blank-disk.bats — the guard that stops Phase 3 destroying Windows.
#
# The chosen device is handed to `bootc install --wipe`. Pick wrong and the
# user's Windows installation is gone — the exact outcome wootc exists to make
# impossible. This code had never been executed when these tests were written.
#
# The trap it must never fall into: selecting "any disk that isn't root's". In
# Phase 2 the running root is /dev/nbd0 (the root.disk loopback hosted on the
# Windows NTFS), so that rule excludes nbd0 and happily returns /dev/sda — the
# Windows disk. Emptiness, not non-rootness, identifies the spare drive.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    PICK="$REPO_ROOT/tests/e2e/pick-blank-disk.sh"

    # The lsblk stub MUST be executable, and BATS_TEST_TMPDIR is on /tmp, which
    # is noexec on this repo's dev box. A stub that cannot run makes every
    # assertion below meaningless — the same vacuous-test trap that already bit
    # go-native.bats. Pick an exec-capable dir and PROVE it before trusting any
    # result.
    STUBDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUBDIR"
    printf '#!/bin/sh\ntrue\n' >"$STUBDIR/.probe"; chmod +x "$STUBDIR/.probe"
    if ! "$STUBDIR/.probe" 2>/dev/null; then
        STUBDIR="$HOME/.cache/wootc-bats-disk.$$"; mkdir -p "$STUBDIR"
        printf '#!/bin/sh\ntrue\n' >"$STUBDIR/.probe"; chmod +x "$STUBDIR/.probe"
        "$STUBDIR/.probe" 2>/dev/null || {
            echo "FATAL: cannot create an executable stub — assertions would be vacuous" >&2
            return 1
        }
    fi
    STUB="$STUBDIR/lsblk"
    export LSBLK="$STUB"
}

teardown() {
    [[ "$STUBDIR" == "$HOME/.cache/"* ]] && rm -rf "$STUBDIR"
    return 0
}

# Build an lsblk stub from a table describing the machine.
#   mk_lsblk "sda:disk" "sda:sda1 sda2:ntfs" ...
# Simpler: write the stub inline per test via a heredoc of case arms.
write_stub() {
    cat > "$STUB"
    chmod +x "$STUB"
}

@test "the script is syntactically valid" {
    run sh -n "$PICK"
    [ "$status" -eq 0 ]
}

@test "picks the blank spare disk, never the Windows disk" {
    write_stub <<'STUB'
#!/bin/sh
case "$*" in
  "-dnro NAME,TYPE")  printf 'sda disk\nsdb disk\nnbd0 disk\n' ;;
  "-nro NAME /dev/sda") printf 'sda\nsda1\nsda2\nsda3\n' ;;
  "-nro FSTYPE /dev/sda") printf '\nntfs\nvfat\nntfs\n' ;;
  "-nro NAME /dev/sdb") printf 'sdb\n' ;;
  "-nro FSTYPE /dev/sdb") printf '\n' ;;
  *) printf '\n' ;;
esac
STUB
    run sh "$PICK"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sdb" ]
}

@test "REFUSES when the only non-root disk is the Windows disk" {
    # The critical case. Windows on sda with partitions, root on the nbd0
    # loopback, no spare. A "not root's disk" rule would return /dev/sda here
    # and destroy Windows. This must fail closed.
    write_stub <<'STUB'
#!/bin/sh
case "$*" in
  "-dnro NAME,TYPE")  printf 'sda disk\nnbd0 disk\n' ;;
  "-nro NAME /dev/sda") printf 'sda\nsda1\nsda2\n' ;;
  "-nro FSTYPE /dev/sda") printf '\nntfs\nntfs\n' ;;
  *) printf '\n' ;;
esac
STUB
    run sh "$PICK"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "a whole-disk filesystem with no partition table is NOT blank" {
    # sdb has no partitions but carries an ext4 signature directly — someone's
    # data disk. Partition-count alone would wrongly call this empty.
    write_stub <<'STUB'
#!/bin/sh
case "$*" in
  "-dnro NAME,TYPE")  printf 'sdb disk\n' ;;
  "-nro NAME /dev/sdb") printf 'sdb\n' ;;
  "-nro FSTYPE /dev/sdb") printf 'ext4\n' ;;
  *) printf '\n' ;;
esac
STUB
    run sh "$PICK"
    [ "$status" -ne 0 ]
}

@test "skips nbd/loop/sr/zram even when they look empty" {
    # nbd0 IS the root.disk we are booted from; wiping it destroys the running
    # system. It can present as having no partitions.
    write_stub <<'STUB'
#!/bin/sh
case "$*" in
  "-dnro NAME,TYPE")  printf 'nbd0 disk\nloop0 disk\nsr0 disk\nzram0 disk\n' ;;
  *) printf '\n' ;;
esac
STUB
    run sh "$PICK"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "picks the first blank disk when several exist" {
    write_stub <<'STUB'
#!/bin/sh
case "$*" in
  "-dnro NAME,TYPE")  printf 'sdb disk\nsdc disk\n' ;;
  "-nro NAME /dev/sdb") printf 'sdb\n' ;;
  "-nro FSTYPE /dev/sdb") printf '\n' ;;
  "-nro NAME /dev/sdc") printf 'sdc\n' ;;
  "-nro FSTYPE /dev/sdc") printf '\n' ;;
  *) printf '\n' ;;
esac
STUB
    run sh "$PICK"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sdb" ]
}

@test "no disks at all fails closed" {
    write_stub <<'STUB'
#!/bin/sh
printf '\n'
STUB
    run sh "$PICK"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "a blank disk listed AFTER the Windows disk is still found" {
    # Ordering must not matter; the Windows disk is simply skipped.
    write_stub <<'STUB'
#!/bin/sh
case "$*" in
  "-dnro NAME,TYPE")  printf 'sda disk\nsdb disk\n' ;;
  "-nro NAME /dev/sda") printf 'sda\nsda1\n' ;;
  "-nro FSTYPE /dev/sda") printf '\nntfs\n' ;;
  "-nro NAME /dev/sdb") printf 'sdb\n' ;;
  "-nro FSTYPE /dev/sdb") printf '\n' ;;
  *) printf '\n' ;;
esac
STUB
    run sh "$PICK"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sdb" ]
}
