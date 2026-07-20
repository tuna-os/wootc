#!/bin/sh
# pick-blank-disk.sh — choose a graduate target for Phase 3, or nothing.
#
# This runs INSIDE the Phase-2 guest (shipped as text over the QGA channel) and
# its output is handed to `bootc install --wipe`. A wrong answer destroys the
# user's Windows installation, so it lives in its own file to be testable rather
# than buried as a shell string inside run-e2e.sh.
#
# THE RULE IS EMPTINESS, NOT "not root".
# In Phase 2 the running root is /dev/nbd0 (the root.disk loopback on NTFS), so
# "any disk that isn't root's" cheerfully selects /dev/sda — the Windows disk.
# Emptiness is what actually identifies the spare drive: no partitions AND no
# filesystem signature on the whole device.
#
# Prints the device path and exits 0 on success; prints nothing and exits 1 when
# no blank disk exists. Failing closed is mandatory — the caller must abort
# rather than fall back to a guess.
#
# Env: LSBLK lets tests substitute a stub for lsblk.
LSBLK="${LSBLK:-lsblk}"

for d in $($LSBLK -dnro NAME,TYPE | awk '$2=="disk"{print $1}'); do
    # Virtual/removable devices are never graduate targets:
    #   nbd*  the root.disk loopback we are booted from
    #   loop* other loopbacks
    #   sr*   optical
    #   zram* compressed RAM
    case "$d" in
        nbd*|loop*|sr*|zram*) continue ;;
    esac

    # Partitions: anything past the disk's own row means it is in use.
    parts=$($LSBLK -nro NAME "/dev/$d" | tail -n +2)
    # Filesystem signature directly on the whole device (no partition table).
    fs=$($LSBLK -nro FSTYPE "/dev/$d" | tr -d ' \n')

    if [ -z "$parts" ] && [ -z "$fs" ]; then
        echo "/dev/$d"
        exit 0
    fi
done

exit 1
