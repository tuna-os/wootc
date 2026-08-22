#!/usr/bin/env bats
# mok-enrollment.bats — the custom-kernel Secure Boot contract (#248).
#
# Bazzite (and other Universal Blue akmods consumers) ship a kernel signed by
# the distribution's OWN key: under Secure Boot, Fedora's shim rejects it with
# "bad shim signature" and Phase 2 never boots (run 32588754680). The fix has
# three legs that must all hold: MokManager travels with the boot artifacts,
# the deployer queues the enrollment, and the harness can drive the one-time
# MokManager confirmation a real user does by hand.

DEPLOY=payload/deployer/deploy.sh
E2E=tests/e2e/run-e2e.sh

@test "MokManager (mmx64.efi) travels with the signed boot chain" {
    # Same signed shim-x64 package, staged wherever shim itself is staged.
    grep -q 'mmx64.efi' .github/workflows/release.yml
    grep -q 'mmx64.efi' "$E2E"
    grep -q 'mmx64.efi' tests/e2e/setup-wootc.ps1
    grep -q '"mmx64.efi"' app/deployer_windows.go
    grep -q '"mmx64.efi", filepath.Join("EFI", "fedora", "mmx64.efi"), true' app/installer_esp.go
    # ...and the ownership guard knows about the new destination, or the
    # reinstall path would refuse its own file as another OS's.
    grep -q 'filepath.Join("EFI", "fedora", "mmx64.efi")' app/installer_esp.go
}

@test "the deployer queues MOK enrollment for akmods images" {
    # OPT-IN per image: only the cmdline flag the app sets from the catalog's
    # mokEnroll field triggers the queue. Aurora/bluefin carry akmods certs
    # too but boot on Fedora-signed kernels — cert-presence alone would hand
    # their users a firmware prompt they do not need.
    grep -q 'wootc.mok=enroll' app/installer_esp.go
    grep -q 'func imageNeedsMok' app/app.go
    grep -q 'read_cmdline wootc.mok' "$DEPLOY"
    # Secure Boot check next (no-op otherwise), cert discovery in the
    # deployed root, upstream's own documented password, and a serial marker
    # the harness gates its driver on.
    grep -q 'mokutil --sb-state' "$DEPLOY"
    grep -q '/etc/pki/akmods/certs/\*.der' "$DEPLOY"
    grep -q "printf 'universalblue\\\\nuniversalblue\\\\n' | mokutil --import" "$DEPLOY"
    grep -q 'MOK enrollment queued' "$DEPLOY"
    # Best-effort by design: the call site must not be able to kill a deploy.
    grep -q 'queue_mok_enrollment || true' "$DEPLOY"
    # The user is told about the blue screen BEFORE it appears, password
    # included — an unannounced firmware prompt is a North Star violation.
    grep -q "MOK management" "$DEPLOY"
    grep -q 'universalblue' "$DEPLOY"
    # mokutil is actually in the initramfs (the queue is dead code otherwise).
    grep -q 'mokutil' payload/deployer/Containerfile
    grep -cq 'mokutil' payload/deployer/Containerfile
    [ "$(grep -c 'mokutil' payload/deployer/Containerfile)" -ge 3 ]
}

@test "the harness drives MokManager only behind the no-GRUB discriminator" {
    # MokManager writes nothing to serial; GRUB prints a banner. The keystroke
    # sequence contains 'e' (the password), which at a GRUB menu would open
    # the editor — so the driver must be gated on BOTH the deploy's queue
    # marker AND the absence of the GRUB banner after shim starts.
    grep -q "grep -aq 'MOK enrollment queued' \"\$PTY\" || return 0" "$E2E"
    grep -q 'GRUB version' "$E2E"
    grep -q 'no MokManager this boot' "$E2E"
    # The verdict is the observable: GRUB reached on the boot after the
    # sequence — and the Phase-2 budget stretches for the extra reboot.
    grep -q 'GRUB reached on the boot after MokManager' "$E2E"
    grep -q 'TIMEOUT=$((300 + MOK_EXTRA))' "$E2E"
}

@test "the GUI warns about the one-time MokManager screen for images that need it" {
    # The image entry carries the password; the done screen explains the blue
    # screen before the user ever sees it.
    grep -q '"mokEnroll": "universalblue"' app/data/images.json
    grep -q 'MokEnroll string' app/app.go
    grep -q 'mokEnroll' app/frontend/src/screens/done.js
    grep -q 'Enroll MOK' app/frontend/src/screens/done.js
}
