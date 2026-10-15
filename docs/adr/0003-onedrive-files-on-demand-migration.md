# ADR 0003: OneDrive Files On-Demand Migration & Hydration Strategy (#65)

## Status
Approved RFC / Architecture Specification

## Context
Windows users frequently have user shell folders (Documents, Pictures, Desktop) redirected to **OneDrive** with **Files On-Demand** active. Many of those files then exist only as cloud reparse points that OneDrive did not hydrate (`FILE_ATTRIBUTE_REPARSE_POINT` / `FILE_ATTRIBUTE_OFFLINE`).

---

## 1. Architectural Split: Hydrate in Phase 1, Mount in Phase 2

wootc strictly divides the migration of OneDrive user folders into two independent phases:

| Phase | Timing | Mechanism & Guarantee |
|---|---|---|
| **Phase 1: Phase-1 Hydration (Data Survival)** | Online in Windows prior to reboot | Resolves paths via `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`. Uses supported Windows shell pin attribute commands (`attrib -U +P /s <folder>`) to hydrate cloud-only files locally while the Windows OneDrive client is authenticated. **Guarantees offline file availability on Linux without needing login credentials.** |
| **Phase 2: Post-Boot Cloud Integration (Cloud Sync)** | First boot in Linux | Offers optional first-boot cloud sync tools (e.g. `onedriver` FUSE client for native OneDrive UX, `rclone` for multi-provider coverage). **Optional, skippable, and never required for local file access.** |

---

## 2. Consent, Measurement & Capacity Checks

1. **Pre-Flight Measurement**:
   - `app/clouddrive_windows.go` queries `HKCU\Software\Microsoft\OneDrive\Accounts` to calculate `LocalBytes` and `CloudOnly` sizes.
2. **Honest Capacity Gate**:
   - Compares the `CloudOnly` bytes to hydrate with the available space in `root.disk`.
   - If the hydration size is more than the `root.disk` capacity or the total disk budget, wootc presents an explicit disclosure screen:
     - **Option 1**: Hydrate selected folders/subsets.
     - **Option 2**: Proceed with local-only files (skip un-hydrated cloud files).
     - **Option 3**: Cancel without altering Windows files or pinning state.
3. **Idempotency**:
   - `attrib -U +P` execution is idempotent per file. Markers record the hydration progress. Thus an interrupted run resumes quickly and does not scan a fully hydrated file again.
