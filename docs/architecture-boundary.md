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
| Windows installer GUI + headless CLI (`app/`) | Catalog entries are opaque references handed to the deployer; the pipeline (root disk, ESP chain, BCD, vault, state.json) never inspects them. |
| Boot chain | BCD one-shot → signed shim+grub → kernel on ESP. Wubi-style; nothing bootc about it. |
| Root-disk hosting | NTFS-hosted VHDX/raw file + dracut attach hook (`platform/dracut/99wootc-boot`). Zero bootc references. |
| User Data Bridge (`payload/migration/`) | Passthrough binds, Steam bridge, browser import, folder conversion, polkit policy. Zero bootc references (3 grep hits are comments). |
| Migration dashboard | Reads bridge state files; distro-agnostic. |
| `state.json` lifecycle contract | Deliberately generic vocabulary (staged/armed/deploying/deployed/healthy/failed). |
| E2E harness (`tests/e2e/`) | Drives Windows, QGA, serial; image ref is a passthrough string. |

**bootc-specific (currently ~50 references, all inside `payload/deployer/deploy.sh` + fisherman):**

- fisherman itself (recipe → `bootc install to-filesystem`).
- Post-install verification: ostree deploy-root discovery
  (`/ostree/deploy/*/deploy/*`), BLS entry patching under
  `boot/loader/entries/`, initramfs regeneration via ostree paths.
- Target-signed shim/grub sourcing from `usr/lib/bootupd/updates/`.
- ESP kernel-sync globs (`boot/ostree/*/vmlinuz*`).

## The provisioner contract (adaptation seam)

Someone porting wootc to another deployment method replaces one stage.
Contract, as deploy.sh already implicitly defines it:

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
