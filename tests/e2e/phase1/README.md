# Phase-1 E2E — installer verification without a deploy

Tests **Phase 1 only**: everything `wootc.exe` does on Windows up to the
armed reboot. No deployer boot, no image pull — the whole test runs in
~2 minutes against an already-booted E2E Windows VM (the `--keep` state of
`run-e2e.sh`, or any dockur container with QGA up).

Designed to run on **runner-b** so runner-a (main) and runner-c (VHDX) stay
undisturbed.

## What it exercises

1. Cross-compiles the real product (`GOOS=windows go build`) — the binary users run, not a
   parallel script.
2. Pre-stages deployer artifacts into `C:\wootc\install\` via the Samba
   share (`downloadDeployer` skips files that already exist, so the
   GitHub download becomes a no-op — no network dependency).
3. Runs `wootc.exe install -image ... -username ... -password ...`
   (headless mode) over QGA.
4. Asserts the resulting system state (`assert-phase1.ps1`):
   - `state.json` = `armed`
   - `root.vhdx` exists and `Mount-DiskImage`/`Dismount-DiskImage` works
   - `vault.json` has a `$6$` hash and no plaintext password
   - ESP carries the signed chain: `EFI\fedora\{shimx64,grubx64}.efi` +
     deployer grub.cfg, `EFI\wootc\{deployer-vmlinuz,initramfs}`
   - BCD: "wootc" firmware entry with path `\EFI\fedora\shimx64.efi`,
     armed in the one-shot `bootsequence` (and NOT in `displayorder`)
   - `wootc.exe status` reports `armed`

The ESP-staging port from `setup-wootc.ps1` into Go has landed and was
live-validated on 2026-07-23: a manually armed boot of the Go-staged
chain (shim → GRUB → deployer) reached fisherman. `setup-wootc.ps1`
remains the reference implementation — when the two disagree, the ps1
behavior is the spec (that is the point of proving each step out via
scripts first).

## Driving the actual GUI (UI automation)

The GUI is the native WinUI shell, driven by **drive mode**: run it with
`WOOTC_E2E_DRIVE=1` and it polls `C:\wootc\e2e-drive.json`, operates its
view-models, and reports to `e2e-drive-state.json`.
`run-e2e.sh --gui-install` (`just remote-e2e-gui`) orchestrates the full
GUI-driven three-phase run this way. The earlier CDP recipe for the Wails
WebView2 app was removed with that app (#346).

## Usage

```bash
# On the E2E host with a running wootc-e2e-windows container:
./run-phase1.sh                # build + stage + install + assert
./run-phase1.sh --skip-build   # reuse existing wootc.exe artifact
```
