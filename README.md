# wootc — Windows-hosted bootc Linux

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

## Current status (2026-07-16)

**Working and verified on the E2E rig** (Windows 11 + TPM + Secure Boot under
KVM; see [docs/e2e-architecture.md](docs/e2e-architecture.md)):

- Secure Boot chain: BCD one-shot → Fedora `shimx64.efi` → signed
  `grubx64.efi` → `grub.cfg` at the embedded `/EFI/fedora` prefix → signed
  deployer kernel from the FAT32 ESP. No Access Denied, no unsigned modules.
- Deployer robustness: disk-scan retry, dirty-NTFS detection, `/dev/kmsg`
  serial markers, journal persisted to `C:\wootc\logs\` on failure,
  watchdog + direct-syscall reboot back to Windows on every failure path.
- fisherman reaches the pull stage with podman fully provisioned (conmon,
  crun, netavark, policy.json, registries.conf) and heavy I/O redirected to
  an ext4 scratch loop on the Windows partition (`/var/fisherman-tmp`).

**Milestone (2026-07-16 08:00 UTC): the deployer E2E loop is green.** A full
autonomous cycle completed on the rig: Windows → BCD one-shot → shim/GRUB →
deployer → fisherman → `bootc install` of yellowfin:gnome into root.disk →
`VERIFICATION_SUMMARY` → clean reboot → Windows with a clean NTFS volume.
Fixes that landed on the way: qualified containers-storage ref for the OCI
export, host networking for the install container, storage redirect only
when default storage is RAM-backed (single-copy space model), post-install
coreutils in the initramfs, and a scratch that persists as an image cache
(retries skip the 3.7 GB pull).

**Active blockers, in order:**

0. **Phase-2 boot staging skipped: ostree-unaware verification.** deploy.sh
   detects the installed root by `/etc/os-release` at the filesystem top
   level, but ostree deployments keep it under
   `/ostree/deploy/default/deploy/<hash>/etc` — the check never matches, so
   the dracut-module inject, BLS argument patch, and ESP kernel-sync are
   silently skipped (verification "passes" in 0.5 s). Fix: detect `/ostree`,
   operate on the deployment path, and run the ESP sync unconditionally.

1. **~~Deployer completion — one untested fix out.~~ Done (see milestone).** The last run failed the
   registry pre-flight with `x509: certificate signed by unknown authority`;
   the CA-bundle path fix is committed (`4ac3174`) but the deployer initramfs
   has not been rebuilt and re-deployed to the ESP since. Root cause of the
   long exit-125 saga was a monolithic dracut `inst_multiple` that failed
   silently on missing `restorecon`, dropping conmon/crun/podman from the
   image (`b105a08`).
2. **Phase-2 Linux boot — implemented, untested.** The signed GRUB cannot
   load `ntfs.mod` under Secure Boot, so the installed kernel inside
   `root.disk` is unreachable from GRUB. The ESP kernel-sync resolution
   (deployer copies installed kernel+initramfs to the ESP; `99wootc-boot`
   dracut module does the NTFS/loop work via kernel ntfs3) is implemented in
   `220756a` and needs its first end-to-end run.
3. **Fresh clean-slate E2E run.** The current VM has accumulated manual
   state (BitLocker decrypted by hand, chkdsk cycles, hand-patched
   initramfs). A from-scratch `run-e2e.sh` run must validate the committed
   fixes — including `PreventDeviceEncryption` in `autounattend.xml`, which
   stops Windows 11 OOBE from BitLocker-encrypting C: (unreadable from
   Linux) on new installs.

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

### Build and run

```bash
# Build deployer initramfs + custom GRUB
just build

# Run on Kanpur (~30 min full, ~5 min quick with existing disk)
just kanpur-e2e          # fresh install + deploy
just kanpur-e2e-quick    # skip install (reuse disk)
```

### Kanpur operations

```bash
just kanpur-logs         # tail runner log
just kanpur-status       # grep for PASS/FAIL markers
just kanpur-serial       # watch serial console
just kanpur-check-files  # check root.disk via QGA
just kanpur-restore snap # restore from snapshot

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
4. Watch serial markers via `just kanpur-serial`

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
