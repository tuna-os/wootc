# The bootc boundary — what is generic, what is not

Principle (2026-07-17): wootc keeps a clear boundary between
**bootc-specific** code and **generic Windows→Linux migration
machinery**, so the project can be adapted to other distributions and
deployment methods. The seam is the **provisioner**: the one component
that turns an attached empty block device into a bootable Linux root.

## Where the code stands today

**Generic (no bootc concepts — keep it that way):**

| Component | Notes |
|---|---|
| Windows installer adapters (`app/`) | Wails, headless and RPC adapt into the shared install policy and engine. Image policy/hardware assessment is separate from the provisioner that installs the target. |
| Boot chain | BCD one-shot → signed shim+grub → kernel on ESP. Wubi-style; nothing bootc about it. |
| Root-disk hosting | NTFS-hosted raw disk and dracut attach hook (`platform/dracut/99wootc-boot`); managed VM and native paths have distinct readiness gates. |
| User Data Bridge (`payload/migration/`) | Windows-folder links, copies, Steam bridge, browser import, conversion and policy; preserve existing target content independently of deployment backend. |
| Migration dashboard | Reads bridge state files; distro-agnostic. |
| `state.json` lifecycle contract | Deliberately generic vocabulary (staged/armed/deploying/deployed/healthy/failed). |
| E2E harness (`tests/e2e/`) | Drives Windows, QGA, serial; image ref is a passthrough string. |

**bootc-specific:** current deployment and verification in
`payload/deployer/deploy.sh`, the VM builder, and fisherman include:

- fisherman itself (recipe → `bootc install to-filesystem`).
- Post-install verification: ostree deploy-root discovery
  (`/ostree/deploy/*/deploy/*`), BLS entry patching under
  `boot/loader/entries/`, initramfs regeneration via ostree paths.
- Target-signed shim/grub sourcing from `usr/lib/bootupd/updates/` — at
  install time, and again on every boot: `wootc-esp-sync` copies the
  deployment's current signed chain forward onto the Windows ESP so an
  SBAT revocation cannot strand a machine that booted yesterday (#333).
- ESP kernel-sync globs (`boot/ostree/*/vmlinuz*`).

## The provisioner contract (adaptation seam)

Someone porting wootc to another deployment method replaces one stage.
Contract, as `payload/deployer/deploy.sh` defines it:

**Input:** an attached, empty block device; a recipe
`{image/source, hostname, filesystem, user{name, password_hash}, flatpaks?, luks?}`.

**Output obligations:**
1. A bootable root filesystem on the device (partitioning included).
2. Kernel + initramfs files at a discoverable location, for the ESP sync.
3. The kernel cmdline the installed system needs (today: read from BLS
   entries; a non-BLS distro would return it directly).
4. The initramfs must contain the `99wootc-boot` attach hook (the
   deployer injects it — generic — but regeneration is provisioner-owned).
5. Optionally: a distro-signed shim+grub pair for the Secure Boot chain
   swap (without it, SB requires the deployer's chain to trust the
   target kernel).

Everything else in deploy.sh — disk discovery, NTFS mount, scratch,
telemetry/heartbeat, vault ingest/shred, User Data Bridge install, ESP
sync mechanics, state.json, reboot — is orchestration and stays.

## Shared policy, engine and diagnostics

`app/install_policy.go` checks admission with explicit dependencies for the
system, catalogue, platform, space and profile, not `App`/frontend state.
`app/install_engine.go` owns the execution sequence. Wails, CLI and RPC must not
grow a second copy of policy or privileged install operations. Preparation
stages the image and checks hardware before Fast Startup changes or
creation of `root.disk`. A hardware warning or partial inventory is not a
compatibility pass; see [the user guide](user-guide.md#hardware-warnings-are-not-compatibility-certificates).

### E2E layer attribution

`tests/e2e/lib/layer-evidence.sh` and `layer-evidence.py` separate infrastructure
evidence from Windows-installer/deployer attribution. They are sourceable
adapters, not a second result ledger: all assertions/failures delegate to the
existing `results.sh` / `results.py` authority. A fresh QGA
`guest-info` response within the size limit proves only that infrastructure responds.

Deployer attribution also needs the current run's reset result.
It then needs the exact OEM `RunId` receipt or an existing authenticated `gui-install`
assertion, plus the selected image and fresh, ordered deployer-started/lifecycle metadata.
An old receipt, a mismatch in image identity or a guest that responds cannot supply
that attribution. Even valid attribution never satisfies deployed-system,
Linux-boot, root-disk or user-data assertions; those retain their independent
observations. `tests/unit/test_layer_evidence.py` covers the adapter behavior,
but this documentation update does not claim that suite or a VM run passed.

### Engine and deployer diagnostics

`app/migration_diagnostics.go` will emit records locally as JSON to **stderr**, never RPC
stdout. Records carry `timestamp`, `attemptId`, stable `phase`, `event`,
`duration_ms` and optional `error_code`. Phases include `prepare`, phase IDs from
the generated installer, `commit` and the outer `install`; events are
`phase_start`, `phase_complete`, `phase_error` or `phase_cancelled`.
The only failure codes are `operation_failed` and `cancelled`. This channel
excludes configuration in raw form, passwords, paths, subprocess errors and session
material; the protected journal/lifecycle records remain the recovery authority.
A diagnostic sink failure must not change the privileged operation's outcome.

The deployer packages sourceable `/usr/libexec/wootc-dso-closure.sh`
(`find_ldso`, `dso_closure`) and `/usr/libexec/wootc-lifecycle.sh`
(`write_ntfs_state`, `write_deployer_started`, with explicit image identity).
Container and initramfs packages must carry these modules.
A source test on the host alone does not prove they exist in the boot image.

`/usr/libexec/wootc-migration-diagnostics.sh` supplies deployer phase timing
with the same JSON field names. It uses the boot UUID to identify each try and
`/proc/uptime` for elapsed milliseconds. It writes to stderr and the append-only
deployer log alongside existing text diagnostics.

Stable phases are
`ntfs-mounted`, `scratch-setup`, `bundle-ingest`, `network-wait`,
`registry-preflight`, `fisherman`, `verification` and `reboot`. Each transition
starts the next phase and completes the prior one; cleanup records final
completion/error from the exit status. It uses only `operation_failed` for an
error, never raw errors or credentials. Packages must also carry this module.

Encrypted session envelopes stay on the NTFS source under
`wootc/install/slurp/session`. Do not copy them into installed `/usr/share`
or conflate them with the separate vault/Wi-Fi ingest path. For each target import,
the installed user must explicitly unlock them; see the
[session contract](session-migration.md).

## Catalogue provenance is not support evidence

`app/data/catalog-sources.json` holds the public snapshot of upstream source.
`app/data/catalog-provenance.json` records the reviewed bootc-migrate commit for that snapshot.
`app/data/catalog-policy.json` retains
wootc-owned display, support status, bootloader, family and MOK policy.
Go combines source and policy; `app/data/images.json` is the generated
artifact for packages/E2E, not an independent hand-maintained catalogue.

From the repository root:

```bash
python3 app/catalog_sync.py --check
python3 app/catalog_sync.py
python3 app/catalog_sync.py --revision <reviewed-40-character-lowercase-hex-commit>
```

The first checks offline. The second regenerates from the retained snapshot
and reviewed policy. The last downloads an immutable revision of reviewed source,
validates it, then writes it. Replace the angle-bracket argument
with the reviewed full commit.

Upstream publication does not automatically add
a product or promote its wootc status. Its v1 identity/backend/family rules do
not supply bootloader, MOK, firmware compatibility or wootc runtime acceptance.
An upstream backend change must pass wootc's explicit check for consistent boot policy.
It must not silently change the installed boot chain. Private brand
and enterprise overrides keep the public `Image` contract.

## Working rules

- New features must not import bootc concepts outside the provisioner
  sections. (The bridge, dashboard, state bus, and boot chain comply.)
- Inside deploy.sh, keep bootc-specific logic in clearly-marked sections
  (it largely is: verification + ESP-sync blocks) rather than diffusing
  it, so the eventual extraction into `provisioners/bootc.sh` is a move,
  not a rewrite. Do that extraction when a second provisioner shows up —
  not speculatively before.
- The GUI catalog schema may grow a `provisioner` field then; today the
  implicit value is `bootc`.
