# wootc — Windows-hosted bootc Linux

<p align="center">
  <a href="https://tuna-os.github.io/wootc/e2e/latest/">
    <img src="https://tuna-os.github.io/wootc/e2e/latest/preview.webp"
         alt="wootc end-to-end walkthrough — Windows 11 → wootc deployer → native Linux → Windows 11"
         width="760">
  </a>
  <br>
  <em>▶ Latest end-to-end run (sped-up): Windows 11 → wootc deployer → native Linux from <code>root.disk</code> → Windows 11. <a href="https://tuna-os.github.io/wootc/e2e/latest/">Click to play the timelapse.</a></em>
</p>

## North Star

Make it as easy as possible for **non-technical Windows users** to migrate
to Linux **without losing any of their data** — and make switching as
convenient as it can be. The goal is to increase Linux adoption by making
it dramatically more approachable. Every design decision is weighed
against: *would a non-technical Windows user get through this without fear
or data loss?* Reversibility and data safety beat feature count; friendly
language beats technical precision in the UI; nothing permanent changes on
the user's machine until Linux is proven working.

wootc installs a bootc-based Linux system into `root.disk`, a sparse file on
an unencrypted Windows NTFS volume. It is a Wubi-style design: no repartitioning
of the Windows OS volume is required, and removal is deleting the installation
directory and its Windows boot entry.

This is early, boot-path-focused development. The project currently targets a
specific acceptance path:

```
Windows 11 → wootc deployer → native Linux from root.disk → Windows 11
```

Native loop-root boot is the implementation priority. The VM experience,
graphical installer, User Data Bridge, and Windows-removal migration are not
implemented yet.

## Current status (2026-07-17)

**Single branch:** all work is merged to `main` (PR #6, plus GUI PRs #4/#5);
E2E runners (dilli, himachal) sync from `main` via `just remote-sync` and
carry no local edits. The fisherman submodule tracks `tuna-os/fisherman`
branch `dev`, which unifies the NBD-preservation and OCI-export fix lineages.

**Working and verified on the E2E rig** (Windows 11 + TPM + Secure Boot under
KVM; see [docs/e2e-architecture.md](docs/e2e-architecture.md)):

- Secure Boot chain: BCD one-shot → Fedora `shimx64.efi` → signed
  `grubx64.efi` → `grub.cfg` at the embedded `/EFI/fedora` prefix → signed
  deployer kernel from the FAT32 ESP. No Access Denied, no unsigned modules.
- **Rung 1 green (24/24):** the Phase-1 harness (`tests/e2e/phase1/`) proves
  the real `wootc.exe` arms a virgin Windows VM over QGA: root disk created,
  signed chain + deployer staged, BCD one-shot set, `state.json = armed`.
- **Deployer E2E loop green (2026-07-16):** Windows → shim/GRUB → deployer →
  fisherman → `bootc install` of yellowfin:gnome into root.disk →
  `VERIFICATION_SUMMARY` → clean reboot → Windows with a clean NTFS volume.
- **GUI Phase 1 landed:** launchpad + control panel, BitLocker chooser,
  partition-aware reversible uninstall, LUKS encryption plumbing,
  Boot-in-VM (QEMU/WHPX), Playwright mock suite green, walkthrough
  published to GitHub Pages.
- **Migration bridge unit-proven (33/33):** User Data Bridge, Steam/browser
  bridges, MS Office→LibreOffice, ESP sync on BLS and classic layouts —
  awaiting a green rung-2 boot for live proof.

**Active work, in order:**

1. **Rung 2 — Phase-2 boot:** fresh full runs on dilli and himachal with the
   unified fisherman fixes (qemu-nbd preserved during partitioning, coherent
   podman store for OCI export, host networking for the install container).
   Runner hardening landed: verified deployer-reboot detection (serial +
   QGA return, not a bare marker wait), size-aware preflight, snapshot-based
   reuse runs.
2. **Phase-2 ESP kernel-sync** — ostree-aware staging works end-to-end;
   remaining fight is initramfs size on small ESPs (the 512 MB ESP in
   `autounattend.xml` removes the pressure structurally).
3. **Remaining SPEC items** (see [docs/plan.md](docs/plan.md)): NTFS defrag
   preflight, VM-accelerator detection + QEMU bundling, polkit hookup,
   systemd-boot advanced option, CDP suite on a Windows runner.

The MOK-enrollment alternative (custom signed GRUB with ntfs+loopback) stays
on the table if ESP kernel-sync proves insufficient. A BitLocker-mode E2E
variant (root.disk on a dedicated unencrypted partition, per SPEC §3.5) is
worth adding once the normal path is green.

## Implemented path: Phase 2 native boot

1. The Windows installer creates `C:\wootc\disks\root.disk`, downloads the
   deployer kernel/initramfs and Fedora-signed shim + GRUB EFI binaries, and
   writes a one-shot Windows Boot Manager entry.
2. The Secure Boot chain is **`shimx64.efi → grubx64.efi → grub.cfg`** (all
   Microsoft/Fedora-signed). Deployer kernel+initramfs live on the ESP (256 MB)
   since the signed GRUB can only read FAT32.
3. The deployer mounts the Windows NTFS volume, attaches `root.disk` to a loop
   device, and uses fisherman to partition and populate it from a bootc image.
4. After deployment, it adds the `99wootc-boot` dracut module to the target,
   adds `wootc.host_uuid` and `loop=/wootc/disks/root.disk` to the target BLS
   entries, regenerates the initramfs, and syncs the installed
   kernel+initramfs to `ESP:/EFI/wootc/phase2-*` with a matching GRUB entry
   (ESP kernel-sync, `220756a`).
5. On the Phase 2 boot, GRUB loads the synced kernel from the ESP; dracut
   (`99wootc-boot`) mounts the NTFS host volume read-write, attaches
   `root.disk`, and pivots to the target root. **Not yet exercised
   end-to-end** — see Active blockers above.

## Future phases (not implemented)

### Phase 1: VM boot and User Data Bridge

The intended first-use experience is to boot the same `root.disk` in QEMU
while Windows remains running. Windows data would be presented to Linux through
a User Data Bridge (virtio or network sharing) at the same canonical paths that
native boot will later use.

This repository does not currently provide the QEMU launcher, Windows
Hypervisor Platform integration, shared-folder bridge, user-directory mapping,
or the graphical UI/control panel for this phase.

### Phase 3: standalone Linux

After a user has migrated data from Windows storage to native Linux storage,
the intended final state is removal of Windows and the NTFS dependency. At that
point `root.disk` may be replaced by a native disk layout.

No data-migration assistant, storage conversion, Windows removal workflow, or
rollback UX has been implemented.

## Repository layout

- `app/` — Wails Windows installer.
- `payload/deployer/` — one-shot initramfs and deploy script.
- `payload/wubildr/` — reproducible custom GRUB EFI build.
- `platform/dracut/99wootc-boot/` — Phase 2 loop-root hook.
- `platform/grub/` — external GRUB configuration.
- `tests/e2e/` — KVM-backed Windows 11 test harness.

## E2E expectations

The E2E harness runs on Kanpur (a Bluefin/Fedora Silverblue KVM host) with
QEMU Guest Agent as the control plane. The VM requires KVM, UEFI Secure Boot,
and TPM 2.0.

### Latest automated walkthrough

[![Sped-up preview of the latest successful wootc E2E run](https://tuna-os.github.io/wootc/e2e/latest/preview.webp)](https://tuna-os.github.io/wootc/e2e/latest/)

The scheduled and manually dispatched KVM workflow publishes this preview and
the full [WebM recording](https://tuna-os.github.io/wootc/e2e/latest/e2e.webm)
only after a successful acceptance run. Failed-run recordings remain available
as workflow artifacts for diagnosis and never replace the stable walkthrough.

### Build and run

```bash
# Build deployer initramfs + custom GRUB
just build

# Run on a remote runner (~30 min full, ~5 min quick with existing disk)
# Pick the host with WOOTC_E2E_HOST (default: kanpur), e.g.
#   WOOTC_E2E_HOST=dilli just remote-e2e
just remote-sync              # push + hard-reset host checkout to origin/main
just remote-e2e               # fresh install + deploy
just remote-e2e-quick         # skip install (reuse disk)
```

### Remote runner operations

```bash
just remote-logs              # tail runner log
just remote-status            # grep for PASS/FAIL markers
just remote-serial            # watch serial console
just remote-check-files       # check root.disk via QGA
just remote-restore snap      # restore from snapshot

# QGA interaction
just qga-ping            # ping guest agent
just qga-ps hostname     # run PowerShell
just qga-read C:/OEM/wootc-e2e.log  # read file from VM
just qga-oem-log         # read OEM log
just qga-reboot          # reboot Windows VM
```

### Debug loop (see docs/e2e-architecture.md for diagrams)

The deployer has **no interactive input** — the serial console is read-only.
Failures must reboot to Windows on their own. Debugging is:

1. Read the deployer journal via QGA: `C:\wootc\logs\deployer-last-journal.log`
2. Patch the initramfs on Kanpur (`bsdtar newc + zstd`)
3. Re-arm the BCD one-shot and reboot into deployer
4. Watch serial markers via `just remote-serial`

The full test is still under active development. The Phase-2 Linux boot leg is
the active blocker; do not yet treat this as a released installer.

## Constraints

- The Windows host volume must be unencrypted. BitLocker-protected volumes are
  not directly mountable by Linux's NTFS driver.
- Windows Fast Startup must be disabled; Linux needs a clean, writable NTFS
  volume. A dirty NTFS volume blocks the deployer immediately.
- **Secure Boot blocks unsigned GRUB modules.** The deployer uses the
  Fedora-signed shim + GRUB chain. Kernel and initramfs live on the FAT32 ESP.
- Initramfs root is **ramfs** (not tmpfs). Heavy I/O must target a disk-backed
  ext4 scratch loop on the NTFS volume or RAM is exhausted mid-deploy.
- Serial console is **read-only** during deployer phase. All diagnostics are
  pushed out via `/dev/kmsg` and persisted to `C:\wootc\logs\` before reboot.

See [docs/SPEC.md](docs/SPEC.md) for the broader design,
[docs/e2e-architecture.md](docs/e2e-architecture.md) for the boot-chain diagrams,
and [CONTEXT.md](CONTEXT.md) for the project vocabulary.
