#!/usr/bin/env bash
# Source-only helpers for the Phase-2 MokManager driver in run-e2e.sh.

# Succeeds only when the serial span since a MISSED MokManager countdown shows
# the untrusted kernel being refused by GRUB and nothing starting after it.
# MokManager deletes the enrollment request when its countdown runs out, so
# this is a terminal state for the run: Phase 2 cannot boot until someone
# queues the key again from Linux. Run 38755153727 (bazzite:stable): GRUB
# printed "bad shim signature" (wrapped across two serial lines, hence the
# "bad shim" match) and parked at its menu; run 38776066218 reset from there
# and MokManager never came back.
mok_missed_boot_refused() {
    local span="${1:-}"
    printf '%s\n' "$span" | grep -aq 'bad shim' || return 1
    # Anything that started after the refusal — a kernel, or Windows with its
    # NTFS volumes — is a different boot; never reset on top of it.
    local after
    after=$(printf '%s\n' "$span" | awk '/bad shim/{seen=1} seen')
    if printf '%s\n' "$after" | grep -aqE 'Linux version [0-9]|EFI stub:|starting Boot'; then
        return 1
    fi
    return 0
}
