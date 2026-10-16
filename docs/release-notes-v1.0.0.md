<!-- wootc-release-notes: draft -->

# wootc v1.0.0 — "The North Star, checkable"

> **Draft.** This file is the release body for `v1.0.0`.
> `release.yml` refuses to publish while the draft marker on line 1 is present
> (`tools/release/check-notes.sh`). Replace each *To add* slot with a link to
> its evidence. Then remove the marker in the same PR that records the
> last evidence.

**Milestone**: [M5 / #213](https://github.com/tuna-os/wootc/issues/213) ·
**Cut issue**: [#242](https://github.com/tuna-os/wootc/issues/242) ·
**Source SHA**: *To add: the final green SHA of the soak (#239)*

## What 1.0 means

wootc helps a person who uses Windows move to Linux without loss of data.
Version 1.0 does not count features. It makes the four criteria in the
[roadmap](../ROADMAP.md#what-10-means) checkable, and each criterion links to
its evidence below.

### 1. The app guides the whole journey

A person without technical skills installs the app and opens Linux inside
Windows. Later, that person chooses native boot of the same system, with a
route back to Windows.

- Usability run with no instructions (M5.1, [#236](https://github.com/tuna-os/wootc/issues/236)):
  *To add: link to the report*
- VM-first journey on the native shell ([ADR 0004](adr/0004-restore-vm-first-product.md), #178):
  *To add: link to the GUI proof run*

### 2. No known causes of data loss

Every destructive path has two gates and an action that you can reverse.

- Destructive paths against the RC inventory (M5.2, [#237](https://github.com/tuna-os/wootc/issues/237)):
  *To add: link to the verified [inventory](destructive-paths.md)*
- Uninstall restores the machine on real hardware (M5.3, [#238](https://github.com/tuna-os/wootc/issues/238)):
  *To add: links to the two machine reports*

### 3. Evidence, not claims

- 30 green nightlies on the native shell (M5.4, [#239](https://github.com/tuna-os/wootc/issues/239)):
  *To add: the dates and the [soak ledger](soak.md) rows*
- Full matrix at the RC SHA, BitLocker and offline included
  (M5.5, [#240](https://github.com/tuna-os/wootc/issues/240)):
  *To add: link to the matrix runs*

### 4. A trustworthy first impression

- Signed binaries, winget, and fresh-machine checks
  (M5.6, [#241](https://github.com/tuna-os/wootc/issues/241)):
  *To add: the two `checklist.md` reports from `tests/field/verify-fresh-machine.ps1`*
- Upstream projects approve their branded installers
  ([upstream blessings](upstream-blessings.md)):
  *To add: the decision for each brand*

## What is not in 1.0

These items are out of 1.0 by decision, not by omission.

- **Third-party migration plugins.** The M4.4 decision
  ([#232](https://github.com/tuna-os/wootc/issues/232)) keeps 1.0 to the
  migrators that ship in the image. Version 1.0 does not load external code.
  Plugins from other parties come after 1.0
  ([plugin architecture §8](plugin-architecture.md#8-10-vs-post-10-scope-boundary)).
- **Try-in-VM as a separate feature.** M4.3
  ([#231](https://github.com/tuna-os/wootc/issues/231)) closed. Then
  [ADR 0004](adr/0004-restore-vm-first-product.md) made the VM the first
  experience instead of an option.
  *To add: confirm the final VM-first scope at the RC SHA*
- *To add: each axis that is still closed in `GetSupportPolicy()` at the
  RC SHA, for example `tpm2-luks` (#33) and btrfs (#35)*

## Upgrade and uninstall promises

- **Upgrade.** *To add: what happens to an install from a pre-1.0 release*
- **Uninstall.** Uninstall removes the boot entry, the bootloader files, and
  the installer. It keeps `root.disk` unless you select its removal. It
  removes a dedicated Linux partition only when wootc created it and the
  volume label proves it ([the uninstall promise](philosophy.md#the-uninstall-promise)).
  *To add: link to the M5.3 hardware proof*

## Where we announce

*To add: the channels that each brand agreed to in M3.6
([upstream blessings](upstream-blessings.md))*
