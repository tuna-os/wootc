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
    # Secure Boot check next (no-op otherwise), cert discovery via the
    # harvested stash, upstream's own documented password, and a serial
    # marker the harness gates its driver on.
    grep -q 'mokutil --sb-state' "$DEPLOY"
    # bazzite's actual key path (its own installer imports exactly this file),
    # plus the classic akmods layouts for other lineages.
    grep -q '/usr/share/ublue-os/sb_pubkey.der' "$DEPLOY"
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

@test "MOK certs are harvested before the verify tree is unmounted" {
    # queue_mok_enrollment runs after /mnt/verify is unmounted and the loop
    # detached — a $DEPLOY_ROOT glob there reads an empty mount point, so
    # every image reported "no distribution certs" (run 32624885089, bazzite,
    # which DOES ship /etc/pki/akmods/certs/akmods-ublue.der). Discovery must
    # happen inside the verify block, and composefs images must be asked via
    # the container image — the deployment's /usr is a stub and its /etc only
    # the writable upper layer, so image-shipped certs appear in neither.
    local harvest umount_line queue_line
    harvest=$(grep -n 'MOK_CERT_STASH=/run/wootc-mok-certs' "$DEPLOY" | head -1 | cut -d: -f1)
    umount_line=$(grep -n 'umount /mnt/verify 2>/dev/null || err' "$DEPLOY" | head -1 | cut -d: -f1)
    queue_line=$(grep -n '^queue_mok_enrollment || true' "$DEPLOY" | head -1 | cut -d: -f1)
    [ -n "$harvest" ] && [ -n "$umount_line" ] && [ -n "$queue_line" ]
    [ "$harvest" -lt "$umount_line" ]
    [ "$umount_line" -lt "$queue_line" ]
    # The composefs answer: certs pulled out of the container image rootfs.
    grep -q 'cert harvested from container image' "$DEPLOY"
    grep -q 'find /etc/pki/akmods/certs /usr/share/ublue-os' "$DEPLOY"
    # Enrollment consumes the stash, never the (dead) on-disk paths.
    grep -q 'find "${MOK_CERT_STASH:-/run/wootc-mok-certs}"' "$DEPLOY"
}

@test "the harness drives MokManager from its own serial marker, not GRUB's absence" {
    # Run 32651824930 disproved the original model: MokManager DOES write to
    # serial ('Press any key to perform MOK management' + a countdown) and
    # AUTO-CONTINUES into GRUB after 10 seconds — where the untrusted kernel
    # dies 'bad shim signature' and the firmware loops back into MokManager.
    # The old no-GRUB-banner discriminator read that pass-through banner as
    # 'no MokManager this boot', stood down, and the box sat unanswered for
    # the rest of the run. The driver must key off MokManager's own marker,
    # and a GRUB banner may prove success only after a driven sequence AND a
    # re-read that shows no fresh shim rejection (the error prints seconds
    # AFTER the banner).
    grep -q "grep -aq 'MOK enrollment queued' \"\$PTY\" || return 0" "$E2E"
    grep -q 'Press any key to perform MOK management' "$E2E"
    grep -q 'bad shim signature' "$E2E"
    grep -q 'GRUB proceeded without a shim rejection' "$E2E"
    run grep -q 'no MokManager this boot' "$E2E"
    [ "$status" -ne 0 ]
    # Bounded retry across the bad-shim loop, and the Phase-2 budget still
    # stretches for the extra reboot(s).
    grep -q 'two MokManager sequences sent' "$E2E"
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
