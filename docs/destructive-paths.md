# Destructive-path inventory — audit in progress

Reviewed source: `0ccddb8eef43da13336e341f6ffdb1381df4684d`, 2026-09-27.
This inventory supports [#234](https://github.com/tuna-os/wootc/issues/234).
It does not establish zero known data-loss classes or satisfy the final RC
verification in [#237](https://github.com/tuna-os/wootc/issues/237).

Each row separates a source gate from its observed proof. A label, directory
name, successful command, or missing response does not prove ownership or
restoration. Temporary-file tests do not establish real-disk recovery.
The table includes product data deletion inside the storage directory because
it can destroy user work even when no external path changes.

| Operation and source | Current gates | Reversal or failure behavior | Proof and remaining gap |
|---|---|---|---|
| Allocate `root.disk`: `app/root_disk_creation.go`, `app/disk_windows.go`, `app/app.go` | Backend refuses any existing path before pipeline operations; exclusive file creation; positive size and final regular-file/size check | Existing image preserved; newly allocated partial image retained on failure; recovery is a separate action | #444 merged. Actual temporary-file existing/equal-size/symlink/racing/concurrent controls pass on Linux and Windows. Native initializer is mocked; actual VDL/full install is not proved by these tests. |
| Shrink C:, create/format data volume: `app/disk_windows.go:CreateDataPartition` | Minimum requested size; supported-size check; PowerShell stop-on-error; BitLocker suspension limited to one reboot | No measured restoration of C: after a later creation/format/ACL failure | **Open #234/#197**: target uses supported maximum rather than binding prior actual size; `UseMaximumSize` can consume other free extents. Creation receipt and exact extent/size observations are still required. |
| Remove data partition and extend C:: `app/disk_windows.go:removePartitionAndExtendC` | UI option; label/type/disk checks | Current code deletes by drive letter; extension failure occurs after deletion | **Open #197/#234**: current label is not creation proof; enumeration errors and foreign descendants must refuse; stable partition/disk/source-C identity must be checked at actual deletion and after resize. Receipt repair is a draft, not current-main proof. |
| Change hibernation/Fast Startup: `app/installer_windows.go`, `app/power_state.go` | Prior-state marker; install/recovery/uninstall paths | Restoration attempts recorded prior settings | Parser tests in `app/power_state_test.go` and `tests/unit/uninstall-restoration.bats` do not prove actual Windows restoration on real hardware. RC verification remains #237/#238. |
| Create/arm firmware BCD entry: `app/installer_esp.go:configureBCD` | Export prior BCD; staged boot assets; saved entry GUID; pipeline cancellation/failure disarm | Backup import is available; cleanup attempts disarm | **Open #286/#234**: real interrupted transactions and ownership-preserving rollback remain required. Historical successful boot cycles do not prove every partial write. |
| Cancel/recover/uninstall BCD cleanup: `app/installer_esp.go:disarmOneShot`, `deleteWootcBCDEntries`, `app/recovery_windows.go` | Saved GUID or entry description used by cleanup | Clears firmware bootsequence and attempts entry deletion | **Open #234/#286**: command errors discarded; GUID only prefix-validated; clearing whole bootsequence can affect other entries; failed BCD enumeration becomes false absence in `hasWootcBCDEntry`. Need foreign-entry and failed-observation counterexamples through actual cleanup. |
| Initial ESP kernel/loader/config staging: `app/installer_esp.go`, `payload/deployer/deploy.sh` | Product ownership manifest and selected boot chain | Existing boot backup/cleanup paths; multiple files change | **Open #286/#234**: immutable whole-chain rollback and process-cut firmware acceptance required. Cross-vendor transition cannot use the upgrade's mixed-trio assumption. |
| Uninstall ESP files: `app/esp_cleanup.go` | Raw relative-path validation; modern manifest authority; regular-file/no-symlink checks; complete preflight | Removes exact claims; observes whole-plan absence; keeps manifest on partial failure for retry; preserves foreign neighbors | #442 merged. Actual temporary filesystem tests reject traversal, ambiguous case, directory claims and lying removers. Nine Windows tests pass, one case-ambiguity test skips on NTFS and passes on Linux. No real ESP mutation in that proof. |
| Delete installed disk/staged data: `app/installer_windows.go:uninstallWith` | DeleteRootDisk/RemovePartition options; default keeps existing disk | Recursive cleanup removes installer subtrees; verification follows | **Open #234**: namespace-based recursive removal and discarded removal errors need ownership/error review; partition receipt must be validated before deleting its metadata. Default preservation is distinct from explicit root-disk deletion consent. |
| Read host volumes and mount selected host NTFS read-write: `payload/deployer/deploy.sh:scan_for_root_disk` | Read-only scan, root image discovery; selected volume then mounted read-write | Unmount/retry/diagnostic paths | `tests/unit/scan-root-disk.bats`, NTFS state-writer and clean-unmount checks cover components. **Open #234/#370**: bind actual host identity at writes and prove dirty/hibernated/failed-observation behavior; source scan alone is not data-loss clearance. |
| Advance VDL, attach loop and provision image: `payload/deployer/deploy.sh` | Selected root image; loop layout and deployment verification | Writes inside raw image; failure diagnostics and Windows return | Existing successful native-cycle runs prove their exact cells. **Open #234/#285/#286**: interruption/retry must preserve an existing installed image; a boot-ready size is not installation consent. |
| Format helper target/scratch: `payload/builder/wootc-builder.sh:blank_disk`, `prepare_storage` | Both block devices, dedicated serials, whole-disk type, minimum sizes, no partitions/signatures/mount before first format | Disposable dedicated disks; installation failure reported | Helper storage preflight evidence exists; it does not prove target desktop or restart. #178 remains open. Identity changes between preflight and mutation still need final audit. |
| Installed ESP kernel/initramfs/config refresh: `payload/migration/wootc-esp-sync` | Host ESP configuration; chosen installed deployment | Per-file `.new`/rename; no whole-set durable transaction in current main | **Open #286/#333/#234**: ownership must precede every write, whole-set interruption recovery and native ancestry must be observed. Native graduation currently copies old host-ESP state. |
| Signed shim/GRUB/MokManager refresh: `payload/migration/wootc-esp-sync:sync_signed_chain` | Current-main candidate/ownership checks | Per-file archive/restore | **Open #333/#286**: current-main checks are insufficient. Draft real signature/db/dbx/SBAT verification, immutable trio archive, durable journal and process-cut recovery have isolated tests; production integration and firmware upgrade boot acceptance remain unproved. |
| Native graduation to blank whole disk: `payload/migration/wootc-go-native:graduate_to_disk_execute` | Explicit execute plus destructive harness flag; blank target checks; local bootc image | Source Windows/root image retained; newly formatted target changed | Historical GUI run36265248670 proves its blank-disk cell. Does not prove same-disk shrink/reclaim, user VM-work persistence, or native boot clearing the former host-ESP configuration (#178/#286). |
| Same-disk shrink/reclaim plan: `payload/migration/wootc-go-native:graduate_plan` | Prints a plan and non-destructive shrink assessment | Executable path is restricted to whole-disk graduation | Printed `ntfsresize`/`sfdisk` commands are **not implemented acceptance**. Do not claim same-disk rollback from that text. |
| Write/move imported user files: `payload/migration/wootc-mount-user-dirs`, `wootc-convert-dir`, plugin imports | Profile map, category operation and bridge paths | Category-specific rollback and ledger; contracts differ per importer | Migration component suite proves seeded cases only. #427 actual BitLocker editor save/reopen/second-boot proof is running on draft434; no result yet. Audit all importer overwrite/collision paths before #234 closure. |
| Shred staged vault, Wi-Fi exports and recovery key: `payload/deployer/deploy.sh`, `payload/migration/wootc-wifi-bridge`, `wootc-umount-user-dirs` | Product staging paths and import/unmount flow | Credentials deliberately removed; `rm` fallback does not promise physical erasure | #279 machine-bound recovery-key storage and #281 staged session envelope lifecycle remain open. Verify exact ownership and failure cleanup; never retain secret values as audit evidence. |

## Field-report corpus

On 2026-09-27, `gh issue list --state all --label field-report --limit 100`
returned no issues. This is a label-query result, not evidence that no user
data was lost. A complete corpus review must also inspect issue bodies,
unlabelled reports, and the RC hardware reports before #234 can close.
No report has been reclassified as harmless from its title or a green test.

## Remaining verification

This is the first reviewed source inventory, not an exhaustive clearance.
Registry/task registration, ACL changes, BitLocker protector handling,
per-importer collision rules, all OEM script equivalents and failure after
each external write still need individual rows with actual positive and
negative evidence. Existing issues cited above retain these gaps; draft
repairs cannot turn a row green until their reviewed source is merged and
their required acceptance scope is observed. Signing, hardware uninstall,
offline, native shell and soak requirements remain independent gates.
