# wootc v0.3.0-beta Release Notes — "The whole matrix, honestly"

**Release Milestone**: M3 (`v0.3.0-beta`)  
**Tracking Issue**: [#211](https://github.com/tuna-os/wootc/issues/211)  
**Status**: Shipped | **Date**: 2026-09-02  

---

## Executive Summary

**v0.3.0-beta** represents the milestone where wootc's support policy stops saying "alpha" because the evidence exists. Every image marked `green` in the catalog is proven across Windows editions; BitLocker-encrypted systems are supported without weakening Windows security or requiring disk decryption; profile migration edge cases (non-Latin usernames, localized accounts, and over-the-shoulder UAC elevation) are comprehensively handled; and all UI claims are strictly backed by empirical matrix evidence.

---

## Milestone M3 Deliverables & Evidence

### 1. Full-Tier Matrix Green across Catalog Images and Windows Editions (M3.1 / #222)
* **Status**: Complete & Verified.
* **Evidence**: [`tests/e2e/matrix.tsv`](../tests/e2e/matrix.tsv), [`app/data/images.json`](../app/data/images.json).
* The full-tier matrix exercises the complete ladder across every green catalog entry:
  * **Images**: Universal Blue Bluefin LTS (`bluefin:lts`), Bluefin current (`bluefin:stable`), Dakota composefs (`dakota:latest`), Aurora (`aurora:stable`), Bazzite (`bazzite:stable`), Yellowfin GNOME (`yellowfin:gnome`), and Bonito GNOME (`bonito:gnome`).
  * **Windows Editions**: Windows 11 Pro, Windows 10 Pro, Enterprise Eval, and LTSC.
  * **Boot Chains**: GRUB2 and systemd-boot with composefs verification.
* Transient QGA communication drops are classified and retried automatically rather than masking legitimate regressions ([#220](https://github.com/tuna-os/wootc/issues/220), [#320](https://github.com/tuna-os/wootc/pull/320)).

### 2. BitLocker Install Path Green & Policy Flip (M3.2 / #223, #34)
* **Status**: Complete & Verified.
* **Code**: [`app/app.go`](../app/app.go), [`docs/manual-testing.md`](../docs/manual-testing.md), [`docs/RELEASING.md`](../docs/RELEASING.md).
* `BitLockerSupported: true` is now enabled on the `beta` channel in `GetSupportPolicy()`.
* On BitLocker-enabled PCs (the Windows 11 default), wootc creates an unencrypted dedicated volume (`wootc-data`) for `root.disk` or utilizes an existing unencrypted partition without decrypting `C:`.
* Numerical recovery passwords are securely captured to allow read-only mounting and user data bridging during Phase 2.
* Clear instructions for BitLocker recovery and returning to Windows are documented in `docs/manual-testing.md`.

### 3. Profile Migration Edge Cases & Identity Integrity (M3.3, M3.4 / #197, #224, #225)
* **Status**: Complete & Verified.
* **Non-Latin Usernames (#224)**: Profiles with non-ASCII characters (CJK, Cyrillic, accented Latin) receive deterministic fallback Linux usernames (`winuser1`, `winuser2`, ...) while preserving full directory mapping in the vault and Phase-2 User Data Bridge. No user profile is silently dropped.
* **Localized Built-in Accounts (#224)**: Built-in system accounts across English, French, German, Spanish, Italian, Portuguese, Russian, Ukrainian, Polish, Dutch, Swedish, Turkish, Chinese, Japanese, Korean, Czech, and Hungarian are excluded from generating phantom Linux accounts.
* **Over-the-Shoulder UAC Identity Derivation (#225)**: When a standard user elevates using administrator credentials, wootc inspects elevation environment variables (`WOOTC_ORIGINAL_USER`, `WOOTC_INTERACTIVE_USER`), CIM/WMI `Win32_ComputerSystem.UserName`, and the interactive `explorer.exe` process owner to ensure the interactive desktop user becomes the primary Linux user.
* **Dedicated Volume Label Gate (#225)**: `dedicatedVolumeInfo` and `removePartitionAndExtendC` strictly require the filesystem label `wootc-data` and 0 extraneous non-system files before claiming volume ownership. Empty user personal partitions without the label are protected from accidental removal during uninstallation. The verified volume label is explicitly named in the uninstall confirmation dialog.

### 4. Branded Installer E2E Cells Proven (M3.5 / #226)
* **Status**: Complete & Verified.
* **Code**: [`app/data/images.json`](../app/data/images.json), [`tests/e2e/matrix.tsv`](../tests/e2e/matrix.tsv).
* Branded installer builds for **Bazzite** (`ghcr.io/ublue-os/bazzite:stable`), **Aurora** (`ghcr.io/ublue-os/aurora:stable`), and plain **Bluefin** (`ghcr.io/projectbluefin/bluefin:stable`) have passed full GUI-driven ladder verification and graduated to `status: green` in the catalog.

### 5. Upstream Blessings Governance (M3.6 / #227, #319)
* **Status**: Complete & Verified.
* **Code & Docs**: [`app/branding/README.md`](../app/branding/README.md), [`docs/upstream-blessings.md`](../docs/upstream-blessings.md), [`packaging/brands.sh`](../packaging/brands.sh), [`packaging/winget/render-brand.sh`](../packaging/winget/render-brand.sh).
* Established formal governance and decision tracking for brand assets, names, taglines, and winget namespaces. Unblessed builds are reported in release logs and can be gated with `WOOTC_REQUIRE_BLESSING=1`.

### 6. Session Migration Honesty (M3.7 / #228, #347, #1)
* **Status**: Complete & Verified.
* **Code & Docs**: [`docs/session-migration.md`](../docs/session-migration.md), [`app/frontend/src/screens/migrate.js`](../app/frontend/src/screens/migrate.js), [`app/frontend/src/screens/done.js`](../app/frontend/src/screens/done.js).
* Clear disclosure that browser and app sessions are staged and require one-time re-authentication upon first login in Linux ("staged — you'll sign in once on Linux").

### 7. Support Policy Audit & Channel Gates
* **Status**: Complete & Verified.
* **Tests**: [`app/support_gate_test.go`](../app/support_gate_test.go).
* Every flag in `GetSupportPolicy()` maps directly to verified matrix cells:
  * `alpha`: Restricts to proven baseline images (`bluefin:lts`), unencrypted disks, and built-in catalog entries.
  * `beta`: Unlocks all green and experimental images, enables BitLocker support, and allows custom OCI refs (unless branded).
  * `stable`: Full production capabilities.

---

## Verification & Test Results

* **Go Test Suite**: `go test -C app ./...` passes (100% green).
* **DTO Generator**: `go run ./tools/gendto .` executed cleanly; `shell/Wootc.Shell/Engine/Dto.cs` in sync with Go definitions.
* **Unit Tests**:
  * `TestDeriveHumanUsernameUAC`: Verifies interactive human resolution across UAC elevation scenarios.
  * `TestDedicatedVolumeLabelGate`: Verifies `wootc-data` label enforcement across all partition states.
  * `TestBetaOffersBitLocker`, `TestBetaOffersExperimental`, `TestAlphaPolicyGatesScenarios`, `TestStablePolicyOpensAllGates`: Verifies support policy contracts.
* **GUI Spec**: `tests/gui/gui.spec.js` updated to verify dedicated volume label display and protection against personal partition removal.
* **Phase-1 E2E**: `tests/e2e/phase1/assert-phase1.ps1` asserts `wootc-data` label on dedicated data partitions.
