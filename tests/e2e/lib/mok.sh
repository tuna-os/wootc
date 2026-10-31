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

# Prints the catalog's mokEnroll value for <image-ref> (empty when the image
# needs no enrollment, is absent, or the catalog cannot be read). This is the
# field the app's imageNeedsMok reads to put wootc.mok=enroll on the deployer
# cmdline, so the script path (setup-wootc.ps1) asks for enrollment for
# exactly the images the GUI path does. Keyed on the catalog, never on an
# image or brand name: run 39886118219 (bluefin:stable) showed a non-bazzite
# image needing the key too.
mok_catalog_enroll() {  # <catalog.json> <image-ref>
    local catalog="$1" ref="$2"
    [ -r "$catalog" ] || return 0
    "${PYTHON_BIN:-python3}" -I -c '
import json, sys
try:
    entries = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for entry in entries if isinstance(entries, list) else []:
    if isinstance(entry, dict) and entry.get("imageRef") == sys.argv[2]:
        print(entry.get("mokEnroll") or "")
        break
' "$catalog" "$ref" 2>/dev/null || true
}
