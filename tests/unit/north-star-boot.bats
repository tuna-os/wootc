#!/usr/bin/env bats
# North Star boot-experience contracts (docs/finish-plan.md, README North
# Star): the parts of the boot flow a nervous, non-technical Windows user
# actually experiences. Each test pins a promise the audit of 2026-08-22
# found broken — these are UX invariants, not implementation details.

DEPLOY="payload/deployer/deploy.sh"
CONTAINERFILE="payload/deployer/Containerfile"
MODSETUP="payload/deployer/module-setup.sh"

@test "the Phase-2 boot menu says the word Windows" {
    # The dual-boot contract ("you're always one reboot away from Windows")
    # is worthless if the boot screen never says the word: the audit found a
    # single "wootc Linux" entry and no Windows entry anywhere. Both grub
    # menu writers (composefs + generic) must carry a Windows chainload.
    [ "$(grep -c 'menuentry "Windows" {' "$DEPLOY")" -ge 2 ]
    [ "$(grep -c 'chainloader /EFI/Microsoft/Boot/bootmgfw.efi' "$DEPLOY")" -ge 2 ]
}

@test "the Linux entry is named for the product, and stays the default" {
    # The distribution's name, not the internal codename — and default=0 so
    # unattended boots (and every E2E flow that boots the default entry) are
    # unchanged. The name arrives via the vault (branded installers,
    # docs/branding-and-distribution.md); everything else stays TunaOS.
    run grep 'menuentry "wootc Linux"' "$DEPLOY"
    [ "$status" -ne 0 ]
    [ "$(grep -c 'menuentry "${DISTRO_NAME}" {' "$DEPLOY")" -ge 2 ]
    [ "$(grep -c '^title ${DISTRO_NAME}$' "$DEPLOY")" -ge 2 ]
    # The default when no brand rode along, and the injection guard: a menu
    # title has no quoting escape hatch, so the vault-supplied name is
    # stripped of grub metacharacters before it lands in one.
    grep -q 'DISTRO_NAME="${VAULT_DISTRO_NAME:-TunaOS}"' "$DEPLOY"
    grep -q "tr -d '\"\$\`" "$DEPLOY"
}

@test "product Phase-2 boots quiet; observed runs keep the verbose consoles" {
    # A real user's new OS must not greet them with a kernel wall on every
    # boot. The E2E classifier depends on the verbose serial, so the split
    # is by observation mode (console=ttyS0 on the deployer cmdline), with
    # BOTH strings defined in one place.
    grep -q 'PHASE2_CONSOLE_FULL="console=tty1 console=ttyS0,115200 earlycon=uart8250,io,0x3f8,115200n8 ignore_loglevel"' "$DEPLOY"
    grep -q 'PHASE2_CONSOLE_FULL="quiet"' "$DEPLOY"
    # No menu writer may hardcode the karg policy any more.
    run grep '^options ' "$DEPLOY"
    [ "$status" -eq 0 ]
    run bash -c "grep -E 'linux /EFI/wootc/phase2-vmlinuz .*ignore_loglevel' '$DEPLOY'"
    [ "$status" -ne 0 ]
}

@test "product tool output never scrolls over the splash" {
    # Observed runs keep stdout on the console (the E2E serial evidence);
    # product runs route it away — the VGA belongs to the reassurance
    # screen. kmsg + persistent log + staged journal keep the diagnostics.
    grep -q 'exec >/dev/null 2>&1' "$DEPLOY"
    grep -B3 'exec >/dev/null 2>&1' "$DEPLOY" | grep -q 'WOOTC_OBSERVED'
}

@test "a verified deploy re-arms the next boot — but never under E2E observation" {
    # The audit's number-one finding: "All set! Starting your new Linux
    # system..." followed by Windows booting, because the one-shot was
    # consumed and nothing product-side re-armed it. The deployer now sets
    # BootNext (one-shot: Windows stays the default). The harness manages
    # its own re-arm from Windows, so observed runs must skip this.
    grep -q 'rearm_bootnext()' "$DEPLOY"
    grep -A2 'rearm_bootnext()' "$DEPLOY" | grep -q 'WOOTC_OBSERVED.*return 0'
    grep -q -- '--bootnext' "$DEPLOY"
    # Called on the success path, before the final splash message.
    success_call=$(grep -n '^rearm_bootnext$' "$DEPLOY" | head -1 | cut -d: -f1)
    [ -n "$success_call" ]
}

@test "the final splash message is only 'starting Linux' when a Linux boot is armed" {
    # When the re-arm failed (or efibootmgr is absent), saying "Starting
    # your new Linux system" and then booting Windows is the exact broken
    # promise the audit flagged. The unarmed path must say Windows.
    grep -q 'All set! Restarting into Windows' "$DEPLOY"
    grep -B2 '"All set! Starting your new Linux system..."$' "$DEPLOY" | grep -q 'WOOTC_REARMED\|WOOTC_OBSERVED'
}

@test "efibootmgr ships in the deployer initramfs" {
    grep -qE '^\s*efibootmgr \\' "$CONTAINERFILE"
    grep -q 'efibootmgr' <(grep -A6 -- '--install' "$CONTAINERFILE")
    # And the build fails loudly if it ever goes missing.
    grep -q 'ntfs-3g efibootmgr' "$CONTAINERFILE"
}

@test "the splash tells the truth past the promised 15 minutes" {
    # The bar easing parks at the fisherman ceiling while a slow download
    # runs 30-60 minutes; the footer claimed "5 to 15 minutes" the whole
    # time, which reads as a hang. Past the promise, the copy must change.
    grep -q 'a big download can take 30-60 minutes' "$DEPLOY"
    grep -q '"$frame" -ge 450' "$DEPLOY"
}

@test "staged boot artifacts come with their manifest" {
    # The app's fail-closed verification (#53/#194) needs a SHA256SUMS; the
    # harness stages the artifacts itself, so it must stage the manifest
    # beside them — and the app must prefer that pre-staged manifest (the
    # offline-bundle contract) over a release fetch that 404s in E2E.
    grep -q 'sha256sum "$f" >> SHA256SUMS' tests/e2e/run-e2e.sh
    grep -q '"SHA256SUMS") { if (Test-Path' tests/e2e/run-e2e.sh
    grep -q 'install", "SHA256SUMS"' app/deployer_windows.go
    # wubildr.efi is best-effort in the release pipeline and mmx64.efi only
    # exists in releases after #248, so the app must treat exactly those two
    # as optional — a release without them must not brick every online
    # install — while everything else stays fail-closed.
    grep -q 'func isOptionalArtifact(name string) bool { return name == "wubildr.efi" || name == "mmx64.efi" }' app/deployer_windows.go
    grep -q 'wubildr.efi || rm -f release-assets/wubildr.efi' .github/workflows/release.yml
}

@test "something is on screen before the network is up" {
    # GRUB → network-online was an unmeasured black-screen stretch right
    # after the scariest click of the migration. A pre-trigger hook paints
    # first reassurance before udev settle.
    [ -f payload/deployer/early-splash.sh ]
    grep -q 'Your Windows and all of your files are safe' payload/deployer/early-splash.sh
    grep -q 'pre-trigger/10-wootc-early-splash.sh' "$MODSETUP"
    grep -q 'early-splash.sh' "$CONTAINERFILE"
}

@test "a wootc firmware entry can never survive in the permanent boot order" {
    # The done screen promises "Windows stays your default until Linux has
    # proven it works". A half-created bcdedit /copy (#74's transient) left a
    # zombie "wootc" entry in the firmware BootOrder ahead of Windows, so the
    # first boot after a verified deploy went straight into Linux (aurora run
    # 32633715971: stale Boot0004 booted Phase 2; Boot0003 "Windows Boot
    # Manager" never ran). Three legs:
    #   1. the sweep pulls every wootc entry out of displayorder BEFORE the
    #      delete — the smaller NVRAM write succeeds when /delete repeats the
    #      transient, and an entry in no boot order is inert;
    #   2. the fresh entry is removed from displayorder after arming — the
    #      one-shot lives in bootsequence alone;
    #   3. the E2E reset sweeps firmware entries too, not just ESP files, so
    #      one run's zombie cannot fail the next.
    grep -q '"bcdedit", "/set", "{fwbootmgr}", "displayorder", m\[1\], "/remove"' app/installer_esp.go
    # ...and the delete still follows it (removal alone would leak objects).
    grep -A1 'displayorder", m\[1\], "/remove"' app/installer_esp.go | grep -q '"bcdedit", "/delete", m\[1\]'
    grep -q '"bcdedit", "/set", "{fwbootmgr}", "displayorder", guid, "/remove"' app/installer_esp.go
    grep -q 'bcdedit /set {fwbootmgr} displayorder \$g /remove' tests/e2e/run-e2e.sh
    grep -q 'bcdedit /delete \$g' tests/e2e/run-e2e.sh
}
