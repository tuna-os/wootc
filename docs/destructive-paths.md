# Destructive-path inventory — M4.6 audit record

Reviewed source: `5002438059bd747146f61e3f3763461fbc1968ca` (2026-10-18).
This inventory supports [#234](https://github.com/tuna-os/wootc/issues/234).
It records source gates, failure behavior, tests, and evidence limits. It is not
the execution review for [#237](https://github.com/tuna-os/wootc/issues/237).
That issue still needs an RC SHA and a full-tier run.

**Working-tree follow-up, 2026-11-02:** the source updates below are not an RC
clearance or a published release. Component checks and isolated runtime
observations retain their stated boundaries; real Windows mutation, firmware,
BitLocker editing and same-system promotion remain separate gates.

## Review method and status

The review walked `app/` and `payload/`, enumerated the relevant mutation
primitives, and reconciled them with the tests and field-report entry points.
The pinned `fisherman` submodule has a separate row. This checkout does not
initialize submodules. Its selected-data path follows the pinned commit, not a
branch.

For each mutation, the inventory records:

- the precondition and the second confirmation or observation before mutation;
- what remains reversible, retained, or retryable after a failure; and
- the test or live evidence and the boundary that evidence does not cross.

`Open` marks an unresolved item, not clearance. A row turns green only after its
gate and reversal pass on the release candidate. Temporary files, mocked
commands, or an empty issue search do not prove user-data safety.

The table includes product data deletion inside the storage directory because
it can destroy user work even when no external path changes.

| Operation and source | Current gates | Reversal or failure behavior | Proof and remaining gap |
|---|---|---|---|
| Allocate `root.disk`: `app/root_disk_creation.go`, `app/disk_windows.go`, `app/app.go` | Backend refuses any existing path before pipeline operations; exclusive file creation; positive size and final regular-file/size check | Existing image preserved; newly allocated partial image retained on failure; recovery is a separate action | #444 merged. Actual temporary-file existing/equal-size/symlink/racing/concurrent controls pass on Linux and Windows. Native initializer is mocked; actual VDL/full install is not proved by these tests. |
| Shrink C:, create/format data volume: `app/disk_windows.go:CreateDataPartition` | Durable `.pending` authority is reserved before mutation; source/disk identity is captured and rechecked after formatting; PowerShell stops on error; BitLocker suspension is limited to one reboot | A failed creation retains the pending marker and does not authorize deletion; a created partition stays preserved if receipt persistence fails | `app/disk_windows.go`, `app/partition-policy.ps1`, and `app/partition-policy.tests.ps1` cover the source and receipt contracts. **Open #234/#197**: no measured restoration of C: after a later shrink/format/ACL failure, and `UseMaximumSize` still needs exact extent/size proof. |
| Remove data partition and extend C:: `app/disk_windows.go:removePartitionAndExtendC` | Requires the durable creation receipt and explicit removal; `Get-WootcPartitionRemovalBinding` re-enumerates the disk and partition and matches GUID, drive, source, and disk; deletion and extension each require a positive observation | A `.deleted` receipt records observed deletion; extension can be retried from the receipt; mismatches and failed observations retain ownership data and refuse | `app/partition-policy.ps1` and `app/partition-policy.tests.ps1` cover identity swaps, failed removal, failed resize, and false success. **Open #237**: the actual Windows deletion/extension run is still required. |
| Native Manage/Recovery destructive action: `app/native_maintenance.go`, `app/native_install_session.go` | Strict action shape; session, brand, and single-use intent binding; fresh engine observations; original-user revalidation; the same facts are rechecked immediately before `UninstallWith` or boot repair | Malformed, replayed, foreign, or changed plans refuse before the action; uninstall keeps `root.disk` by default and reports incomplete cleanup | `app/native_maintenance_test.go` covers plan shape, replay, changed observations, and refusal. The test records a fake action; no real Windows mutation is proved (#237). |
| Native install confirmation: `app/native_install_session.go`, `app/native_install_authorization_windows.go` | Typed immutable install plan; image/storage validation; captured-user revalidation; session/brand/one-shot intent binding; fresh observation immediately before starting the existing install pipeline | A failed or mismatched confirmation consumes the intent; the existing install pipeline owns rollback and disarm behavior | `app/native_install_session_test.go`, `app/native_install_session_windows_test.go`, and the authorization path cover protocol and replay refusal. The native shell has no full destructive hardware run yet (#237). |
| Change hibernation/Fast Startup: `app/installer_windows.go`, `app/power_state.go` | Prior-state marker; install/recovery/uninstall paths | Restoration attempts recorded prior settings | Parser tests in `app/power_state_test.go` and `tests/unit/uninstall-restoration.bats` do not prove actual Windows restoration on real hardware. RC verification remains #237/#238. |
| Create/arm firmware BCD entry: `app/installer_esp.go:configureBCD`, `armBootChain`, `app/boot_txn.go` | Export prior BCD; hash check of the staged ESP chain before entry creation and again before the arm; journal `install/boot-txn.json` records each step; the one-shot is the last change before reboot | Each step compares `bcdedit /enum firmware` with the intended chain. A failure or cancel removes the entry and reads the store again. Residue keeps the journal in `rollback-unconfirmed`, and the startup task tries again | #286: tests in `app/boot_txn_test.go` cut power at each boundary and fail each step against a simulated store. **Open #234**: a Windows VM run with real interruptions is still necessary. |
| Cancel/recover/uninstall BCD cleanup: `app/installer_esp.go:disarmOneShot`, `deleteWootcBCDEntries`, `app/recovery_windows.go` | Journal/saved full GUID or owned entry description; strict firmware-store observation | Failed enumeration refuses instead of becoming false absence. Rollback must be observed before recovery tasks, EFI files or state can be removed; failure retains retry authority | Working-tree failure controls cover unreadable stores and retained state. **Open #234**: actual Windows cleanup and interruption counterexamples remain required. |
| Initial ESP kernel/loader/config staging: `app/installer_esp.go`, `payload/deployer/deploy.sh` | Product ownership manifest and selected boot chain | Existing boot backup/cleanup paths; multiple files change | **Open #286/#234**: immutable whole-chain rollback and process-cut firmware acceptance required. Cross-vendor transition cannot use the upgrade's mixed-trio assumption. |
| Uninstall ESP files: `app/esp_cleanup.go` | Raw relative-path validation; modern manifest authority; regular-file/no-symlink checks; complete preflight | Removes exact claims; observes whole-plan absence; keeps manifest on partial failure for retry; preserves foreign neighbors | #442 merged. Actual temporary filesystem tests reject traversal, ambiguous case, directory claims and lying removers. Nine Windows tests pass, one case-ambiguity test skips on NTFS and passes on Linux. No real ESP mutation in that proof. |
| Delete installed disk/staged data: `app/installer_windows.go:uninstallWith` | Explicit DeleteRootDisk/RemovePartition choices; partition receipt validated before metadata removal; secret scrubbing must succeed | Removal errors propagate. Default preservation retains unfamiliar saved data even when `root.disk` is absent; failed scrub retains the secret and its retry authority | Working-tree component controls cover preservation and failure propagation. **Open #234**: explicit deletion namespace, partition mutation and actual Windows interruption acceptance remain required. |
| Discard an unfinished attempt's `root.disk` before a resume: `app/install_recovery.go:prepareResumeAt` | Re-observes and re-classifies on every call. The journal starts only after the gate that refuses an existing `root.disk`. The attempt must have reached "Making room for Linux" and stopped before the boot steps. `armed.json` and `deployer-started.json` must be absent, and the file must not be older than the attempt | Verified download pieces are kept. Any doubt refuses the resume and offers removal instead | `app/install_recovery_test.go` refuses an older file, a touched boot chain, and a started deployer, and confirms that a refused resume keeps the file. Uses temporary files only. No interrupted Windows VM run proves it yet (#287). |
| Read host volumes and mount selected host NTFS read-write: `payload/deployer/deploy.sh:scan_for_root_disk` | Read-only scan, root image discovery; selected volume then mounted read-write | Unmount/retry/diagnostic paths | `tests/unit/scan-root-disk.bats`, NTFS state-writer and clean-unmount checks cover components. **Open #234/#370**: bind actual host identity at writes and prove dirty/hibernated/failed-observation behavior; source scan alone is not data-loss clearance. |
| Advance VDL, attach loop and provision image: `payload/deployer/deploy.sh` | Selected root image; loop layout and deployment verification | Writes inside raw image; failure diagnostics and Windows return | Existing successful native-cycle runs prove their exact cells. **Open #234/#285/#286**: interruption/retry must preserve an existing installed image; a boot-ready size is not installation consent. |
| Format helper target/scratch: `payload/builder/wootc-builder.sh:blank_disk`, `prepare_storage` | Install operation only: both block devices, dedicated serials, whole-disk type, minimum sizes, no partitions/signatures/mount before first format | Disposable dedicated disks; installation failure reported; export is a separate read-only operation | Helper storage preflight does not prove target desktop or restart. Historical #178 is closed; current VM-first acceptance is #596. Identity changes between preflight and mutation still need final audit. |
| Export managed-VM boot inputs: `app/vm_promotion.go`, `payload/builder/wootc-export.sh` | Clean stopped VM, disk lease/GPT/install identity, signed export-capable helper; original target read-only, ephemeral overlay for target-native initramfs generation; exact kernel/closure and archive hashes | Durable export/failure journal and cancellation; separate retained export directory. No ESP/BCD mutation or claim that native boot is armed | Real installed-target helper export, cancellation and byte-identity proof remain required. **Open #596**: host storage/trust/BitLocker/Fast Startup/recovery preflight and transactional native handoff remain unimplemented. |
| Installed ESP kernel/initramfs/config refresh: `payload/migration/wootc-esp-sync` | Resolves the host ESP from the recorded UUID; requires the owned `EFI/wootc` namespace; the direct route writes `.new` then renames; the controller route observes boot identity and ownership before each write | Direct kernel/config replacement is per-file, not a whole-set transaction; the controller retains journal state for recovery and refuses an unprepared boot | `tests/unit/esp-chain-refresh.bats`, `tests/unit/test_wootc_esp_control.py`, and `tests/unit/test_wootc_esp_transaction.py` cover the split paths. **Open #237/#333**: direct pair interruption and real firmware acceptance remain unproved. |
| Signed shim/GRUB/MokManager refresh: `payload/migration/wootc-esp-sync:sync_signed_chain` | `wootc-esp-control:prepare` binds current boot identity, ownership, source package, firmware trust, and signatures; publication accepts only receipt-listed destinations and the prepared boot ID | The transaction archives and recovers the signed trio; an ambiguous source or changed boot refuses before publication | `tests/unit/test_wootc_esp_control.py`, `tests/unit/test_wootc_esp_transaction.py`, and `tests/unit/test_esp_chain_refresh.py` cover the controller. **Open #237/#333**: production integration, process-cut recovery, and firmware-upgrade boot acceptance remain unproved. |
| Native graduation to blank whole disk: `payload/migration/wootc-go-native:graduate_to_disk_execute` | `--to-disk` requires a block device different from the host disk; execution requires `--execute` plus `WOOTC_GN_ALLOW_DESTRUCTIVE=1`; fisherman owns target partition/format checks; the image is already local | Source Windows/root image remains untouched; only the explicitly selected target changes; failure leaves the source available for retry | `tests/unit/go-native.bats` covers the dry-run and destructive flag boundary. Historical GUI run 36265248670 proves a blank-disk cell, not the native shell. User-work persistence and native boot remain open (#237). |
| Same-disk shrink/reclaim plan: `payload/migration/wootc-go-native:graduate_plan`, `cmd_migrate` | `ntfsresize --info` is read-only; `--reclaim` requires native boot and at least one converted folder; in-place execution without `--to-disk` refuses after printing the plan | Current main performs no same-disk shrink, partition delete, or Windows-entry removal; the plan is not rollback evidence | `tests/unit/go-native.bats` proves the dry-run and refusal boundary. The printed `ntfsresize`/`sfdisk`/`efibootmgr` commands are not implemented acceptance; do not claim same-disk safety. |
| Write/move imported user files: `payload/migration/wootc-mount-user-dirs`, `wootc-convert-dir`, plugin imports | Profile map, category operation and bridge paths; Documents copying writes as the receiving ordinary user | Failed Documents copy preserves existing Linux work instead of hiding it under a read-only Windows bind; unsafe empty-mountpoint removal refuses; importer collision rules remain category-specific | Component controls cover seeded failures. **Open #427/#234**: actual BitLocker editor save/reopen/second-boot and importer interruption acceptance remain required; no old draft run is current proof. |
| Import from an external Windows or WSL volume: `payload/migration/wootc-import`, `wootc-wsl-bridge`, `wootc-detect-apps`, `wootc-steam-bridge` | 2026-11-02 source update: running-disk exclusion; BitLocker unlock via stdin; read-only source; explicit categories; standard-file copies publish complete files exclusively, preserve existing destination bytes and refuse source/destination symlinks or special files | Per-category copied/preserved/failed results; failed or unverified categories return nonzero even if others completed. Eject unmounts bind/source and closes mapper. Existing Steam VDF is preserved byte-for-byte; missing entries require manual Add Library. WSL dotfiles, `.ssh` and Brewfile preserve existing different content and use exact new-file ownership rather than recursive chown; per-item outcomes are copied/alreadyPresent/preserved/failed | `tests/unit/import.bats` and `tests/unit/test_plugin_import_results.py` are existing orchestration/result suites; no new execution result is asserted by this source update. **Open #234**: real read-only volume, interrupted publication/eject and complete mixed-category preservation still require runtime evidence. A copied file or preserved VDF does not prove service/account migration. |
| Scrub staged vault/Wi-Fi/recovery secrets: `payload/deployer/deploy.sh`, migration bridges, `app/secret_scrub_windows.go` | Canonical recovery password; checked staging ACLs; verified and durably published sealed copy before removing plaintext; encrypted session envelopes retained on NTFS for explicit consented import, not copied into target `/usr/share` | Failed overwrite/flush retains plaintext and blocks unlink/uninstall for retry. Shutdown retains the bridge credential. Host-only fallback does not protect a copied disk, and overwriting does not promise physical erasure | Component failure controls cover scrub/seal ordering. **Open #279/#427/#234**: actual TPM reset, BitLocker editing and second-boot proof remain required. Never retain secret values as audit evidence. |


| Add/Remove Programs registry and prior-power mirror: `app/installer_windows.go`, `app/sysprobe_windows.go` | Prior power state durably recorded before mutation; `WootcOwner=wootc-install-v1` receipt required for product-key reuse/removal; foreign or unmarked keys refused | Registry errors propagate. Power restoration must be observed before removing its final retry mirror | Working-tree controls cover ownership and failure propagation. **Open #234**: actual Windows foreign-key, failed-write/restoration and retained-retry observations remain required. |
| Boot repair and Windows-only restore (#290): `app/boot_repair.go`, `app/recovery_windows.go:repairBootFromArmed` | Reads `bcdedit /enum firmware` first. Acts only on entries with the `wootc` description. Refuses when the recorded GUID has a different description, when `armed.json` and `bcd-guid.txt` disagree, when the next boot goes to a foreign entry, or when the ESP manifest is unreadable | Restore clears the one-shot and removes wootc entries from the permanent order. It keeps the entry, the ESP files and `armed.json`. Repair passes only when a new observation shows the recorded entry as the next boot and the recorded ESP hashes. If that check fails, repair takes wootc out of the boot order again | Decision-table and command-list tests in `app/boot_repair_test.go` use `bcdedit` dumps, not a real BCD store. A Windows VM run of each action is still necessary. |
| Recovery scheduled tasks: `app/recovery_windows.go:registerRecoveryTasks`, `unregisterRecoveryTasks` | Fixed task names; SYSTEM startup and elevated logon principals; the existing task's executable, arguments, principal, run level, trigger and action/trigger counts must match before reuse or removal | Registration refuses a foreign same-name task before the first BCD write. Cleanup is idempotent for absent tasks, verifies removal, and returns command or observation errors | The task identity is bound to the staged executable and its recorded hash is checked before startup recovery. The broader privileged-state and TOCTOU audit remains open under #234/#370. |
| Trusted state directory ACL: `app/state_trust_windows.go:prepareTrustedStateTree` | Trusted parent volume; restricted creation descriptor; recursive owner/DACL/no-reparse inspection before root ACL update; rejects unsafe existing trees instead of repairing them | Fails before trusting planted artifacts; does not restore earlier ACLs | Component native trust tests exist. #370 remains open for the full reader/writer/transition surface and TOCTOU review; this source gate does not prove every elevated artifact consumer. Dedicated-volume root ACL and OEM equivalent need separate ownership proof. |
| BitLocker recovery-password capture/write: `app/bitlocker_windows.go` | Selected volume and recovery protector; canonical length/digit/checksum/hyphen validation; checked directory/file ACLs | Staging/ACL failure returns error; scrubbing failure preserves retry authority instead of silently deleting the secret | The canonical-format and fail-closed repairs are working-tree changes, not a published release. **Open #279/#370/#427**: actual Windows capture, TPM lifecycle and editor/restart evidence remain required. |
| OEM carve/decrypt/key/BCD equivalents: `tests/e2e/setup-wootc.ps1` | Measured C: shrink; freshly formatted storage; conversion wait; positive BCD path/entry/sequence checks | Per-step cleanup attempts and one-shot rollback | **Open #234/#286**: `UseMaximumSize` still needs exact extent proof; two absent BitLocker objects count as plaintext; BCD rollback drops errors. Harness success cannot clear Go product variants. Frozen draft434 adds a separate complete-C:-encryption readiness gate; its run is not terminal. |
| Native folder conversion swap/marker: `payload/migration/wootc-convert-dir` | Allowed folder, nonempty source, second successful rsync; native destination must be empty; actual empty-directory removal after unmount; final move forbids nesting | Failed swap preserves native files and staging; no new marker; retry preserves Linux edits | #447 merged after all applicable hosted checks. Five actual-script/private-file controls prove successful final placement, repeat-edit preservation, hidden native files, move-time race refusal and the faulty-move mutant. Mount/identity/ownership calls are mocked. **Open #234/#285**: full staging ownership, locking and crash recovery remain unproved. |
| Browser profile import: `payload/migration/wootc-import-browser` | 2026-11-02 source update: FD-pinned no-follow traversal; absolute/traversal/reparse/symlink profiles refuse; Firefox stages a complete profile and publishes with atomic no-replace; Chromium uses exclusive hardlink publication, never overwrite | Existing Firefox import directory refuses and preserves edits. Existing `profiles.ini` is never rewritten/appended; a copied but unregistered profile reports failure/manual-registration advice. Failed/partial copies retain private `.wootc-*.partial` staging and return nonzero; source originals remain unchanged. Browser state is native only for nonempty imports without errors, failed on any error, unchanged for no work, always unverified | Source controls address the prior check-then-copy and repeat-overwrite defects; this edit does not claim tests ran. **Open #234**: validate interrupted publication, real source filesystem semantics and browser metadata registration in runtime fixtures. Neither copied profile nor native category state is authentication proof. |
| Office dictionary/templates/fonts import: `payload/migration/wootc-office-bridge` | 2026-11-02 source update: existing different native templates/fonts/autocorrect/defaults preserved, not counted as migrated; unsafe paths refuse; exact new-file ownership only, no recursive chown | Dictionary append has a recovery journal and refuses changed pending state; per-file outcomes distinguish copied/already-present/preserved/failed. Failure does not authorize replacing native work; inspect journal before retry | Source controls replace no-clobber exit-status/recursive-chown assumptions; this edit does not claim tests ran. **Open #234**: real ownership, interrupted dictionary append, collision and retry acceptance still need retained runtime results; category presence or a successful skipped copy is not evidence a file arrived. |

## Dependency review: selected Windows data before partitioning

On 2026-10-18, review of current main
`5002438059bd747146f61e3f3763461fbc1968ca` and its pinned fisherman
`e2b316600fc68ba397730b39d1eb205dc1f1f240` found another open path.
This review does not clear the other inventory rows.

| Operation and source | Current gates | Reversal or failure behavior | Proof and remaining gap |
|---|---|---|---|
| Copy explicitly selected Windows data before partitioning: fisherman `fisherman/cmd/fisherman/main.go`, `fisherman/internal/slurp/data.go` | Non-manual installation with a supplied slurp configuration; source mounted read-only; byte budget reserves 2 GiB on `/run` | Extraction errors become a non-fatal “Data migration skipped” message. Budget exhaustion can return partial or empty results without an error. The caller then continues toward partitioning. | **Open #234/#237**: source review found no complete-copy gate before the destructive boundary. The stream also skips unreadable files, copy failures, hidden/system names, and files over 500 MB. A reproduced test on the exact pinned source returned a zero budget and `Found=false`; it did not execute partitioning. Required proof: incomplete requested migration stops the actual caller before partition or format, with owned source data unchanged. |

The source test's scratch directory differs from the hard-coded `/run`
capacity observation. A fixed budget can make the test repeatable. It does not
prove that all selected files arrived.

A repair must check each selected file.
It must report each explicit exclusion. It must stop destructive work if the
copy is incomplete. Tests must observe that the actual caller stopped.
A file count or a warning message cannot prove this.

A complete copy in RAM can be lost after shutdown. Before partition or format,
the caller must verify a durable copy on storage outside the target. That copy
and its receipt must survive interrupted writes and failed imports.

## Field-report corpus

Review date: 2026-10-18. GitHub's all-state search and independent
cross-checks returned no submitted field report:

| Search | Result | Interpretation |
|---|---:|---|
| `label:field-report` | 0 issues | No issue carries the template label. |
| `in:title "[hardware]"` | 10 issues/PRs | All are planning issues or PRs; none is a filed run report. |
| `in:body "Build or tag tested"` or `"Overall result"` | 0 issues | No submitted body contains the form's required result fields. |
| `in:body "Uninstall proof"` | 5 issues/PRs | All five are documentation or planning changes, not reports. |

| Report | Cause and fix | Data impact | Disposition |
|---|---|---|---|
| None found | Not applicable | No open filed report describes lost or corrupted user data. An empty corpus does not prove zero loss. | The corpus is empty; no report can be triaged to green, fixed, or filed. |

Issue #216's current closure evidence is #525, which adds the three-machine
protocol but says the real runs still need people with the machines. Issue #210
has no individual report IDs in its body or comments. The open #302 cohort and
#237 RC verification remain the evidence path. This audit does not turn the
absence of reports into a no-loss claim.

The report form itself remains the authoritative intake path:
`.github/ISSUE_TEMPLATE/manual-test-report.yml`.

## Remaining verification

This revision completes the current-main source walk and the issue-corpus
review. It does not claim release-candidate clearance. Rows marked `Open`
remain actionable findings: their gates, reversal behavior, or evidence have
not crossed the boundary stated in the row.

The inventory covers every current-head mutation site in `app/` and `payload/`.
The native shell's install and maintenance consent boundaries are explicit
above. The ESP direct and controlled refresh paths stay separate.
The selected-data path for pinned `fisherman` remains a separate row because an
in-memory partial copy must not come before the partition step.

The next required evidence includes an RC-dated run for every named unit-only
gate. It also includes the real Windows partition and boot interruption
counterexamples, importer collision controls, and durable selected-data
migration. Issues #197, #237, #279, #285, #286, #333, #370, #427, and the
related hardware/cohort gates track these items. A later RC review must diff its
source SHA against this inventory before it marks the rows green.
