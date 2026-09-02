# Borrowed from Libertix — six boot-chain and recovery designs, specified for wootc

[Libertix](https://github.com/ekimiateam/libertix) (Ekimia, GPLv3, WPF + PowerShell +
a Debian live ISO) solves the same problem as wootc — install Linux from inside
Windows without a USB stick — with the opposite disk model: it shrinks C: and
installs to a real partition, where wootc installs into `root.disk` on NTFS.
Its geometry code is therefore irrelevant here. Everything it does *around the
reboot* is not. This document is the result of reading it against wootc's code
(issue #308) and turns each borrowing into a design with a task list.

Nothing here is a code copy. Libertix is GPLv3; these are designs, re-derived
against wootc's own files. The license question only arises if we ever lift
their PowerShell verbatim, and then it is a conversation first.

The North Star governs every choice below: *would a nervous, non-technical
Windows user get through this without fear or data loss?* Each borrowing exists
because today there is a moment where that user is left without an answer.

| # | Borrowing | The moment it fixes | Tracking |
|---|---|---|---|
| 1 | Secure Boot CA-generation preflight | "bad shim signature" after the reboot, with no warning before it | #322 |
| 2 | Recovery guard on the Windows side | Windows comes back and wootc never says what happened | #285 / #287 / #290 |
| 3 | First-boot evidence, cross-checked from Windows | "installed" is claimed by whoever wrote a file last | #285 / #287 |
| 4 | Signed-chain refresh on the ESP after updates | the next SBAT revocation stops a working install from booting | new issue |
| 5 | One step catalogue, diffed in CI | a renamed phase silently blinds the harness or the splash | new issue |
| 6 | Signed catalogue and exe freshness | an old exe fetches artifacts it was never tested with | new issue |

---

## 1. Secure Boot: preflight the CA generation the firmware trusts

### What Libertix does

Its Windows preflight calls `Confirm-SecureBootUEFI` and
`Get-SecureBootDbCertificates`, records whether *Microsoft Corporation UEFI CA
2011* and/or *Microsoft UEFI CA 2023* is in `db`, and refuses to mutate the disk
when Secure Boot is on and the shim it will stage is not signed by a CA the
firmware holds. Its catalogue records the authority per distribution. Its live
ISO ships Debian's shim 16.1, which is dual-signed.

### Where wootc stands (measured)

- `release.yml` extracts `shimx64.efi` from `quay.io/fedora/fedora:44` at
  release time. Fedora 44 ships `shim-x64-16.1-5`, whose Authenticode chain is
  **2011 only**. Rawhide ships `shim-x64-16.1-7`, which is **dual-signed**
  (2011 and 2023). Read directly from the RPMs on koji, and from the shim in
  the `v0.1.0-alpha.1` release, which is the 2011-only build.
- The 2011 CA certificate expired on 2026-06-27. Firmware does not check expiry,
  so a machine holding the 2011 CA keeps booting our shim. Microsoft only issues
  new signatures under the 2023 CA, and new machines increasingly ship without
  the 2011 CA.
- `getSystemInfo` reads BitLocker, UEFI mode, Fast Startup. It never reads `db`.
  `gateScenario` has no Secure Boot clause. On a 2023-only machine the user
  reboots into `bad shim signature`; the firmware falls back to Windows; nothing
  explains it.

### Design

1. **Know what we stage.** `release.yml` reads the PKCS#7 in the shim's PE
   security directory (`openssl pkcs7 -inform DER -print_certs`) and writes
   `shim-authorities.json` (`{"shimx64.efi": ["2011","2023"]}`) beside
   `SHA256SUMS`, listed in it. The build fails if the shim is not signed by at
   least the 2023 CA; the fedora image tag moves to the first release whose
   `shim-x64` is dual-signed (rawhide today; pin the exact NVR once it lands in
   a numbered Fedora).
2. **Know what the firmware trusts.** `SystemInfo` gains `SecureBootEnabled`
   and `TrustedUefiAuthorities []string`. Source: `Confirm-SecureBootUEFI`, then
   `Get-SecureBootUEFI -Name db` parsed as an `EFI_SIGNATURE_LIST` chain
   (X.509 entries, GUID `a5c059a1-94e4-4aa7-87b5-ab155c2bf072`), matching the
   two subject CNs. The PowerShell cmdlet path first, the raw parse as fallback
   on editions without the module.
3. **Gate before arming, in words.** In `gateScenario`: Secure Boot on and
   `trusted ∩ staged == ∅` → refuse with "Your PC's Secure Boot only trusts
   Microsoft's 2023 certificate; this build's boot loader is signed with the
   2011 one. Update wootc, or turn Secure Boot off temporarily." Secure Boot
   off → proceed and record it in the ledger. Unknown (`db` unreadable with
   Secure Boot on) → refuse; guessing is how the user meets the firmware error.
4. **Choose at arm time** when both shims are carried: stage the one the
   firmware trusts, prefer 2023 when both are present. MokManager travels with
   the shim it was built with (#248).
5. **Prove it.** OVMF `db` axis in the harness: 2011-only, 2023-only, both. The
   2023-only cell must show the refusal text and never reach the reboot.

### Tasks
- [ ] build-time signer extraction → `shim-authorities.json`, fail on 2011-only
- [ ] bump the shim source to a dual-signed `shim-x64`, pin the NVR, assert in E2E
- [ ] `SystemInfo.TrustedUefiAuthorities` + `SecureBootEnabled`
- [ ] gate + user text + ledger line
- [ ] harness `db` axis, three cells
- [ ] `docs/user-guide.md` requirements, `SPEC.md` Secure Boot paragraph, `docs/status.md` row

## 2. Recovery guard: when Windows comes back, wootc explains itself

### What Libertix does

Before the reboot it registers two scheduled tasks (`Register-ScheduledTask`,
`-RunLevel Highest`): one `-AtStartup` that runs the recovery guard as SYSTEM,
one `-AtLogOn` that shows the result. The guard reads a `pending.env` written
at arm time plus marker files the live system writes back onto the Windows
volume (`live-started`, `live-failed`, `install-success`). No `live-started`
marker means the reboot never reached Linux: it offers a validated fallback
boot strategy or a full revert. Every rollback action proves ownership of what
it touches by matching recorded disk identity and geometry, and success is
"all completed stages compensated", never "cleanup ran".

### Where wootc stands (measured)

- `state.json` (`app/state.go`) documents six states and says the deployer
  writes `deploying`/`deployed`/`failed` and the first boot writes `healthy`.
  **Nothing outside the installer writes it.** `deploy.sh` never touches it;
  no first-boot unit exists. After a successful deploy the file still says
  `armed`.
- `deployHasCompleted` therefore falls back to "the deployer's journal file
  exists" (`deployer-last-journal.log`), which the failure path also writes.
- On deployer failure `cleanup()` persists the journal, shows a calm card for
  six seconds, and `reboot -ff`. Windows boots (the one-shot was consumed).
  Nothing on the Windows side notices. The user opens wootc, if they think
  to, and the control panel offers uninstall.
- If the one-shot never fires (firmware ignored `bootsequence`, the transient
  BCD copy of #264), Windows boots with an armed entry that may fire later.
- `uninstallWith` is the only compensation path and is all-or-nothing.

### Design

**Arm-time.** `configureBCD` writes `install\armed.json`: BCD GUID, ESP
partition GUID, the manifest of ESP files wootc wrote (already tracked by
`guardESPDestinations`), prior power state, storage drive, image ref, UTC
time. Then it registers `wootc-recovery` (`-AtStartup`, SYSTEM, highest) and
`wootc-recovery-prompt` (`-AtLogOn`, the installing user). Both run
`wootc.exe recover --startup|--prompt` from a copy of the exe under
`install\`, hash-checked against `armed.json` before it runs anything.

**Marker protocol** (all on the storage drive under `wootc\install\`, written
by the deployer while NTFS is mounted, `sync`ed):

| file | writer | meaning |
|---|---|---|
| `deployer-started.json` | `deploy.sh` right after `phase "ntfs-mounted"` | the reboot reached Linux |
| `state.json` = `deploying` | same moment | contract from `state.go`, finally honoured |
| `state.json` = `deployed` | after `vstage "verify-complete"` | Phase-2 ESP is staged |
| `state.json` = `failed` + `phase` | `cleanup()` on non-zero exit | the ledger's own phase word |
| `state.json` = `healthy` | first-boot unit in the deployment (§3) | Phase-2 userspace reached |

**Startup task logic** (`recover --startup`), one decision table, no guessing:

| `armed.json` | `deployer-started` | `state` | verdict | action |
|---|---|---|---|---|
| present | absent | armed | one-shot never booted Linux | disarm: `bootsequence` clear, verify with `bcdedit /enum {fwbootmgr}`; keep ESP files; write verdict |
| present | present | deploying | deployer died without reaching `cleanup` (power loss) | disarm; verdict `interrupted` |
| present | present | failed | deployer failed cleanly | verdict `failed` with its phase and the last 30 log lines |
| present | present | deployed | Phase-2 pending or booted | leave armed; verdict `deployed` |
| present | present | healthy | done | remove both tasks, delete `armed.json` |

Every verdict is written to `install\recovery-verdict.json` atomically
(temp + `MoveFileEx` with `MOVEFILE_WRITE_THROUGH`). The prompt task reads it
and shows one screen: what happened, in the phase's own splash words, that
Windows and files are untouched, and the two buttons that are always true:
**Try again** (re-arm from `armed.json`, same one-shot mechanism as
`BootIntoLinux`) and **Remove** (`uninstall`). `Repair boot` (#290) is the
verdict-specific third button: it re-runs the ESP staging from the manifest
and the BCD arm, then verifies the observable state exactly as the harness
does (`bcdedit /enum firmware`, ESP file hashes).

**Ownership before compensation.** `recover` touches only BCD GUIDs recorded
in `armed.json` or matching the `wootc` description, and only ESP files in the
manifest whose hash still matches what wootc wrote. Anything else is reported,
not removed — the same D1/D1b rule `setupSignedChain` already applies at
install.

**Idempotence.** `recover --startup` can run any number of times; it never
creates a BCD entry, only clears or re-arms the recorded one. The tasks are
removed by `healthy`, by uninstall, and by a successful `Try again` that
re-registers them fresh.

### Tasks
- [ ] deployer writes `deployer-started.json` and honours the `state.json` contract (`deploying`/`deployed`/`failed`) — prerequisite for everything below
- [ ] `armed.json` + task registration in `configureBCD`, removal in `uninstallWith`
- [ ] `wootc.exe recover --startup` with the decision table, atomic verdict file
- [ ] `recover --prompt` screen: verdict → plain words, Try again / Remove / Repair boot
- [ ] harness: kill the deployer at `scratch-setup`, at `fisherman`, and after `verify-complete`; assert the verdict, that Windows boots by default, and that Try again converges
- [ ] `uninstall_check` asserts both tasks are gone

## 3. First-boot evidence, cross-checked from Windows

### What Libertix does

The installed system's first boot publishes `installed-linux-boot.json`
(kernel, root filesystem, account, package audit, decoded `BootCurrent` with
ESP partition GUID and loader path) into the Windows recovery directory. A
hidden startup task on the Windows side compares it with the plan and the
current disk geometry before declaring success and removing temporaries.
Logging is evidence, not a success signal.

### Where wootc stands (measured)

- Phase 2 has `wootc-host-bind.service` (NTFS at `/run/wootc/host`, mounted
  read-write by the attach hook) and `wootc-esp-sync.service` (mounts the
  ESP). The deployment can write to the Windows volume on every boot already.
- Nothing does. `healthy` is never written. The harness proves Phase 2 with
  the North Star file, which is harness-only.
- Windows "knows" the install worked because a journal file exists.

### Design

A oneshot `wootc-firstboot-evidence.service` (after `wootc-host-bind`,
`wootc-passthrough`) in the deployment writes
`/run/wootc/host/wootc/install/installed-linux-boot.json`:

```json
{ "state": "healthy", "kernel": "6.x", "image": "ghcr.io/…@sha256:…",
  "bootCurrent": {"bootNumber": "0004", "espPartitionGuid": "…", "loaderPath": "\\EFI\\fedora\\shimx64.efi"},
  "rootDisk": {"path": "/wootc/disks/root.disk", "hostUuid": "…"},
  "bridge": {"boundFolders": 6, "matchedUsers": 1, "bitlockerUnlocked": false},
  "secureBoot": true, "failedUnits": [], "writtenAt": "…" }
```

`BootCurrent` comes from `efivarfs` (`8be4df61-93ca-11d2-aa0d-00e098032b8c`),
the load option decoded to the hard-drive media device path's partition GUID.
It then sets `state.json` to `healthy` (atomic rename on NTFS) and removes
itself via a `ConditionPathExists=!` on the evidence file.

Windows side: `deployHasCompleted` becomes "evidence file exists **and** its
`bootCurrent.espPartitionGuid` equals the ESP wootc staged **and** the loader
path is ours". The control panel's "installed" card reads kernel, image and
bridge summary from the evidence; the done screen after Phase 3 does the same.
The harness asserts the file on the Phase-2 boot, replacing one of its own
proxies with the product's evidence.

### Tasks
- [ ] `wootc-firstboot-evidence` script + unit, installed by `deploy.sh` beside the bridge units
- [ ] `BootCurrent` decode (Python, no new dependency; `efibootmgr -v` as the fallback source)
- [ ] `deployHasCompleted` requires the evidence; `UninstallInfo` exposes it
- [ ] control panel shows kernel/image/bridge from the evidence
- [ ] harness asserts the evidence after Phase-2 boot; bats pins the unit ordering

## 4. Signed-chain refresh: keep the ESP bootable through updates

### What Libertix does

An APT hook and a systemd `.path` unit resynchronise the package-owned shim,
signed GRUB and MokManager into `EFI/Libertix` after every relevant package
update. The previous chain is archived before an atomic, hash-checked
replacement, with shim replaced last.

### Where wootc stands (measured)

- `wootc-esp-sync` already runs every boot and refreshes **the Phase-2 kernel,
  initramfs and grub.cfg** on the ESP. Good, and it is the right home.
- It never touches `EFI/fedora/{shimx64,grubx64,mmx64}.efi`. Those are the
  Phase-1 copies from the wootc release, static forever.
- Our shim carries SBAT `shim,4`. When the next SBAT revocation is applied by
  Windows Update (Microsoft ships them as part of the Secure Boot certificate
  rollout), the firmware refuses `shim,4` and the install stops booting, one
  day, with no change the user made. The deployment image, meanwhile, ships a
  current signed shim under `/usr/lib/bootupd/updates/EFI/fedora/` (bootupd
  payload) on every `bootc upgrade`.

### Design

Extend `wootc-esp-sync`:

1. **Source**: `/usr/lib/bootupd/updates/EFI/<vendor>/{shimx64,grubx64,mmx64}.efi`
   when present; else `/boot/efi/EFI/<vendor>/` on classic layouts; else skip
   with a log line. `EFI.json` beside them gives bootupd's own version stamp.
2. **Gate**: the candidate shim must be Authenticode-signed by a CA the
   firmware trusts (same parser as §1, run on Linux against `efivarfs` `db`),
   and its SBAT generation must be ≥ the installed one. Refuse a downgrade.
3. **Replace**: archive the current trio to `EFI/wootc/archive/<sha>/`, write
   `.new`, `sync`, rename; **shim last**, GRUB first, matching Libertix's order
   so a power cut mid-replace leaves a shim that still chains a valid GRUB.
   Hash-check after rename; on mismatch restore from the archive.
4. **Ownership**: only files listed in the ESP manifest wootc wrote at Phase 1
   (`guardESPDestinations` manifest, mirrored into `/etc/wootc/esp-manifest`
   by the deployer). Foreign `EFI/fedora` is never touched — the same D1 rule.
5. **Trigger**: every boot (already) plus a `.path` unit on
   `/usr/lib/bootupd/updates/EFI.json` so a `bootc upgrade` staged this boot
   is picked up before the next reboot rather than one late.

### Tasks
- [ ] deployer mirrors the ESP manifest to `/etc/wootc/esp-manifest`
- [ ] `wootc-esp-sync`: signed-chain source discovery + SBAT/CA gate + archive-then-atomic replace, shim last
- [ ] `.path` trigger unit; ordering pins in bats
- [ ] harness: after Phase 2, plant a newer shim in the bootupd path, reboot, assert the ESP trio changed and the archive exists and the system still boots
- [ ] `docs/architecture-boundary.md` line about bootupd sourcing becomes true

## 5. One step catalogue, restated everywhere, diffed in CI

### What Libertix does

`OrderedSteps` exists in C#, PowerShell, Python and the rollback shell script.
CI compares all four; a step cannot be renamed, reordered or forgotten in one
runtime. A separate presentation-only table maps steps to translated labels.

### Where wootc stands (measured)

- Deployer phases: `phase "ntfs-mounted|scratch-setup|network-wait|bundle-ingest|registry-preflight|fisherman|verification|reboot"`, each mapped to splash text in `phase()`.
- The harness greps `fisherman` and `verification` by hand; the failure
  ledger's phase words are its own; `INSTALL_STEPS` in `progress.js` is a
  third list; the Phase-1 pipeline step names in `app.go` are a fourth, and
  `progress.js` matches them by string (`'Making Linux bootable on your machine'`).
- The repository's bats culture already pins strings across files one at a
  time (`mok-enrollment.bats`, `north-star-boot.bats`). There is no single list.

### Design

`payload/steps.tsv` — one file, three columns: `id`, `owner`
(`installer|deployer|firstboot`), `label`. It is the authority. Generated
from it (checked in, regenerated by `just steps`, diffed in CI):

- `app/steps_gen.go` — the Phase-1 step ids and labels (`app.go` pipeline
  uses the constants; `progress.js` receives labels from the backend instead
  of hard-coding them);
- the `phase()` case table in `deploy.sh` (splash text per deployer phase);
- `tests/e2e/steps.sh` — the harness's marker list and the failure ledger's
  allowed `phase` values;
- the recovery verdict's phase vocabulary (§2) and the evidence file (§3).

A bats test asserts every `phase "x"` call in `deploy.sh` is in the catalogue
and every catalogue deployer id has a splash line; a Go test asserts the same
for the pipeline; CI fails when a generated file is stale.

### Tasks
- [ ] `payload/steps.tsv` + generator (`just steps`) + stale-check in CI
- [ ] `app.go` pipeline and `progress.js` consume the generated labels
- [ ] `deploy.sh` splash table generated; harness marker list generated
- [ ] bats + Go parity tests

## 6. Signed catalogue and exe freshness

### What Libertix does

CI signs `catalog.json` and `releases.json` with an RSA key held in Actions
secrets; the public key is compiled in. Stable builds refuse to start when a
newer stable exists. A command-line filepool override is the only unsigned
mode and it shows a permanent warning.

### Where wootc stands (measured)

- Boot artifacts are fetched from `releases/latest/download/` and verified
  against `SHA256SUMS` from the **same** URL, fail-closed (#53). Integrity
  against a corrupt download: yes. Against a moved `latest`: the exe pins
  nothing, so a `v0.1.0-alpha.1` exe fetches `v0.2.0` artifacts and a
  deployer it was never run with. Against a compromised release: nothing; the
  checksum file is as trusted as the artifacts.
- `images.json` is compiled in; `C:\wootc\images.json` overrides it for
  enterprise custom refs, unsigned by design (local admin). The OCI image is
  digest-pinned (`bundle.json`) — that part is right.

### Design

1. **Pin, don't float.** The exe embeds its release tag; `deployerBaseURL`
   becomes `releases/download/<tag>/`. `WOOTC_DEPLOYER_MIRROR` keeps its
   testing role. Version skew between exe and deployer becomes impossible.
2. **Sign the manifest.** `release.yml` signs `SHA256SUMS` with a minisign (or
   cosign keyless, if the org prefers Sigstore) key from Actions secrets →
   `SHA256SUMS.minisig`. The public key is compiled into the exe;
   `fetchChecksums` verifies before parsing. The pre-staged manifest path
   (`install\SHA256SUMS`, used by the offline bundle and the harness) must
   carry its signature too; the harness signs with a test key injected via
   `WOOTC_MANIFEST_PUBKEY`, never the production one.
3. **Freshness, stated not enforced.** On the launchpad, fetch
   `releases/latest` metadata (best-effort, 3 s) and show "a newer wootc is
   available" with the link. Alpha does not refuse to run; that is Libertix's
   stable-channel rule and ours can follow at beta.
4. **Catalogue signature** waits until `images.json` is fetched at runtime;
   today it is part of the signed exe.

### Tasks
- [ ] embed the release tag; pin `deployerBaseURL`; harness override unchanged
- [ ] minisign the manifest in `release.yml`; verify in `fetchChecksums`; test key for the harness and the offline bundle
- [ ] launchpad freshness notice
- [ ] `docs/RELEASING.md`: key custody and rotation

---

## What we deliberately do not borrow

- The UI stack (WPF on .NET Framework 4.8): weighed in #304.
- `ext4-win-driver` (a third-party GPL kernel filesystem driver installed into
  the user's Windows) for "Linux files visible in Windows".
- Decrypt-BitLocker-first. wootc's unencrypted-volume path keeps C: encrypted;
  the one real gap is the recovery key's lifecycle (#279).
- GRUB4DOS and the BIOS/MBR path. wootc is UEFI-only by design.
- The private Proxmox/VNC/vision-model lab. The hosted-runner harness with a
  serial ledger and a published timelapse is a different, deliberate trade.

## Order of work

1. §1 (#322) — a shipping build boots on 2023-only firmware, or refuses in words.
2. §2 prerequisite: the deployer honours `state.json`. Then the guard.
3. §3 — evidence, because §2's `healthy` row needs it.
4. §5 — the catalogue, before §2 and §3 add a fifth and sixth copy of the phase words.
5. §4 — chain refresh, once §1's parser exists to gate it.
6. §6 — pinning is a one-line change worth doing early; signing at the beta gate.
