# GUI + Phase 1 architecture (Windows installer)

Status: proposal, 2026-07-17. Companion to `docs/SPEC.md` §3 and the E2E
learnings accumulated on kanpur. Scope: everything that runs on Windows —
the Wails GUI (`app/`), the install pipeline it drives, and the contract
between the GUI and the deployer across reboots. Phase-2 boot internals are
out of scope (owned by the E2E track).

## 1. Current state

`app/` is a Wails v2 app (fixed 820×620, vanilla-JS frontend, 4 screens:
launchpad → progress → done, plus a control screen when `root.vhdx`
already exists). The Go backend exposes `GetImages`, `GetSystemInfo`,
`StartInstall` (9-step pipeline), `CancelInstall`, `Uninstall`, `Reboot`.
Vault handling (sha512-crypt hash, ACL-restricted `vault.json`, deployer
shreds after ingest) is designed correctly and matches SPEC §2.3.

Hard facts to anchor planning:

1. **The Windows binary does not compile.** `GOOS=windows go build ./app`
   fails: `downloadFile`, `copyFile`, `marshalJSON` are referenced but
   never defined; `espDrive` is declared and unused in `configureBCD`.
   The pipeline has never been executed end-to-end. (Not introduced by
   recent work — it predates the VHDX branch.)
2. **The app installs a boot chain the E2E effort has abandoned.**
   `setupGRUB2` copies `wubildr.efi` + configs to `ESP:EFI\wootc\` and
   points BCD at `\EFI\wootc\wubildr.efi`. The chain proven on kanpur is:
   BCD → `ESP:EFI\fedora\shimx64.efi` (MS-signed) → `grubx64.efi`
   (embedded prefix `/EFI/fedora`) → `grub.cfg` → **deployer kernel +
   initramfs on the ESP** (signed GRUB cannot read NTFS). The reference
   implementation of the working chain is `tests/e2e/setup-wootc.ps1`
   steps 7–8, not the app.
3. **BCD handling differs from what E2E validated.** The app sets both
   `displayorder /addfirst` (permanent — silently changes the user's
   default boot) and `bootsequence /addfirst` (one-shot). E2E uses only
   the one-shot, which is the right UX: nothing permanent changes until
   TunaOS actually works.
4. `setupSystemdBoot` is a stub, but the GUI already offers a
   "Bootloader" choice.

## 2. Target architecture

### 2.1 Components

```
┌────────────────────────────  Windows  ─────────────────────────────┐
│  wootc.exe (Wails)                                                 │
│  ├─ ui/            screens: launchpad, progress, done, control     │
│  ├─ catalog        embedded images.json + C:\wootc\images.json     │
│  ├─ preflight      SystemInfo + hazard checks (§2.4)               │
│  ├─ pipeline       ordered, resumable steps (§2.2)                 │
│  ├─ bootchain      ESP layout + BCD (one implementation, shared    │
│  │                 logic with setup-wootc.ps1 by construction:     │
│  │                 the .ps1 should shrink to a thin caller or be   │
│  │                 generated — today they are two divergent copies)│
│  └─ statebus       reads/writes C:\wootc\state.json (§2.3)         │
│                                                                    │
│  C:\wootc\                                                         │
│  ├─ install\   deployer-vmlinuz, deployer-initramfs.img, vault.json│
│  ├─ disks\     root.vhdx                                           │
│  ├─ logs\      live-journal.log, deployer-last-journal.log         │
│  └─ state.json single source of truth for lifecycle (§2.3)         │
└────────────────────────────────────────────────────────────────────┘
```

### 2.2 Install pipeline (revised step list)

Replace the current 9 steps with the E2E-proven order; every step must be
idempotent so a failed install can be re-run without manual cleanup:

1. Preflight gate (§2.4) — abort before touching anything.
2. Disable Fast Startup.
3. Create directories.
4. Create `root.vhdx` (diskpart, dynamic) + attach/detach self-check.
5. Download deployer kernel+initramfs+signed shim/grub **with sha256
   verification** (SPEC §3.1 promises this; not implemented — release
   pipeline must publish checksums alongside artifacts).
6. Stage ESP: `EFI\fedora\{shimx64,grubx64}.efi`, deployer pair to
   `EFI\wootc\`, deployer grub.cfg at the signed GRUB's prefix.
   **ESP capacity is a first-class constraint** (§3, D2).
7. Write vault.json (unchanged).
8. Configure BCD: create "wootc" firmware entry pointing at shim, arm
   **one-shot** `bootsequence` only. No `displayorder` change.
9. Write `state.json` → `armed`.

### 2.3 Lifecycle state machine + deployer contract

The single biggest UX gap: after the reboot, the GUI currently knows
nothing. kanpur debugging repeatedly needed exactly this information; the
deployer already emits it (phase markers, journal streaming to
`C:\wootc\logs\`) — it just has no consumer.

States (persisted in `C:\wootc\state.json`, written by both sides):

```
absent → staged → armed → deploying → deployed → healthy
                     │         │          │
                     └─────────┴──> failed(phase, error)
```

- GUI writes `staged`, `armed`.
- Deployer (deploy.sh) writes `deploying` on start, then `deployed` or
  `failed` with `{phase, error, ts}` — one `jq`-free echo of JSON to
  `/mnt/ntfs/wootc/state.json` next to the existing log streaming; it
  already has every needed value in `/run/wootc-phase` and the fatal
  message.
- Phase-2 firstboot (wootc-passthrough or a oneshot unit) writes
  `healthy` — closing the loop that a real boot succeeded.
- Control screen renders the state: `failed` shows the phase + tail of
  `deployer-last-journal.log` with a "Retry deploy" button.

**Re-arming must restore the deployer grub.cfg first.** A successful
deploy overwrites the ESP grub.cfg with the Phase-2 menu (this cost a
full debugging cycle on kanpur — re-arming the BCD entry without
restoring grub.cfg boots Phase-2, not the deployer, and if the Phase-2
kernel was pruned from the ESP it dead-ends at a GRUB error). "Retry
deploy" = restore deployer grub.cfg + verify deployer pair on ESP +
one-shot bootsequence + reboot. This belongs in `bootchain` as one
operation; the ad-hoc `restore-deployer-grub.ps1` pattern from kanpur is
the prototype.

### 2.4 Preflight gates (SPEC §3.5, mostly unimplemented)

Blockers (refuse install): not UEFI; no admin; ESP unusable (§D2); free
space < root.vhdx max + deployer scratch headroom (the kanpur
`skopeo copy: exit status 2` failure is what running out looks like —
surface it *before* reboot, not in dracut); BitLocker with unexportable
recovery path.
Warnings (accept + mitigate): BitLocker on (suspend for next boot, per
SPEC §3.5 script); Fast Startup (already handled); Secure Boot state
recorded into `state.json` (chain differs only in confidence, not layout).

## 3. Open architecture decisions (need explicit calls)

**D1 — `EFI\fedora\` collision on real dual-boot machines.** The signed
Fedora grub has embedded prefix `/EFI/fedora`; on a machine with an
actual Fedora install, wootc would overwrite that distro's `grub.cfg`
and shim. The E2E VM never sees this; real users will. Options:
(a) detect an existing `EFI\fedora\` with a BLS-populated grub.cfg and
refuse (MVP-safe, cheap);
(b) coexist: preserve + chainload the original cfg;
(c) longer term: ship a differently-prefixed signed chain (requires our
own shim signing — heavy).
Recommendation: (a) now, design toward (b).

**D2 — ESP capacity.** The deployer initramfs is ~135 MB; OEM ESPs are
commonly 100–260 MB and kanpur's 512 MB ESP already needed manual
pruning. Options: (a) preflight-measure and refuse when it can't fit
(with clear message); (b) shrink the deployer initramfs (it embeds
podman/skopeo/fisherman — a slimmer net-boot-style second stage is a
real project); (c) FAT32 helper partition created by shrinking C: and
pointing shim's grub there via `search`. Recommendation: (a) for MVP with
telemetry on how often it bites, spike (c) after.

**D3 — systemd-boot in the GUI.** Under Secure Boot, sd-boot is not
loadable via shim for EL-family targets (not signed by a trusted vendor
key), and nothing in the E2E chain exercises it. Keep the field in
`InstallConfig` for forward-compat but **hide the choice in the UI for
MVP** — an option that can't work is a support ticket. Revisit alongside
UKI-signed images post-MVP.

**D4 — where the boot-chain logic lives.** Today it exists twice
(`setup-wootc.ps1` for E2E, Go for the app) and they drifted in opposite
directions. Either the app's `bootchain` package becomes the only
implementation and E2E invokes `wootc.exe --headless-install` (best:
E2E then tests the *product*, not a parallel script), or the .ps1 stays
canonical and the app shells out to it. Recommendation: headless mode in
wootc.exe; it also gives enterprises unattended install for free.

## 4. Roadmap (ranked)

1. **Make it compile + CI gate** — add the three missing helpers, fix
   `espDrive`, add `GOOS=windows go build ./app` (and `go vet`) to CI.
2. **Port the proven chain into `bootchain`** — shim/grub staging, ESP
   deployer pair, prefix grub.cfg, one-shot-only BCD (drop
   `displayorder`), D1(a) guard, D2(a) preflight.
3. **state.json contract** — GUI writer + deployer writer (3-line change
   in deploy.sh's log-streaming block) + control-screen consumer with
   log tail and "Retry deploy".
4. **Preflight gates** — space math, BitLocker suspend, checksum
   verification of downloads.
5. **Headless install mode** (D4) — then swap E2E's setup-wootc.ps1 body
   for it.
6. GUI polish: hide bootloader choice (D3), catalog from embedded JSON
   file instead of Go literals, `GetStatus` mutex (races today), surface
   `state.json` history on the control screen.

Items 1–4 are the MVP cut. 5 is the structural payoff that stops the
Windows/E2E drift from ever recurring.
