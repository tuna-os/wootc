# Move a person's digital life to Linux

Status: proposed contract and delivery plan, 2026-09-26.
This document extends [the plugin design](../plugin-architecture.md).
It does not claim that the new runner, APIs, or adapters exist.

The [VM-first product direction](../adr/0004-restore-vm-first-product.md) governs the sequence.
The first customer has an older PC and little technical knowledge.
They want their documents, photos, familiar apps, and preferences within reach.
They should not need to learn what a plugin is.

## What exists and what does not

This audit covers the source on 2026-09-26.

| Area | Present implementation | Gap before a product claim |
|---|---|---|
| WinUI | Go `serve` protocol, tests, and generated `shell/Wootc.Shell/Engine/Dto.cs` | No runnable shell project, views, or native UI proof yet |
| Discovery | `wootc-manifest` discovers manifests and runs `bin/detect` | Failure becomes absent; external paths can shadow built-ins; no enforced sandbox |
| Built-in adapters | Eight manifests: files, browsers, Office, Steam, identity, look, Wi-Fi, WSL | Seven import wrappers emit fixed success lists even if the helper fails or is absent |
| Import execution | Existing bridge scripts and deployer hooks | No shared transaction runner for the declared plugin lifecycle |
| Browser data | Profile/bookmark/history copy paths | Copy completion does not prove app compatibility, login, or every requested item |
| Sessions | Windows consent, key export, authenticated envelopes, staged ledger | Linux unlock/import, supported store versions, and live-session proof remain open |
| Selection | Category and item choices, GTK tools, bridge reports | A common preview and result contract for Windows, Linux, and headless tools |
| Cloud files | OneDrive design and platform-specific code | Per-file local readability, quota accounting, and offline proof for each provider |

The old design has a built-in-only rule for 1.0.
The current scanner also reads environment, administrator, and user paths.
Resolve that mismatch before third-party extensions become a supported feature.
A manifest field such as `requiresAdmin` is not an enforced security boundary.

## One journey across two systems

1. **See what you have.** Scan the current person's profile without changes.
   Show Files, Internet, Mail, Games, Work, and Preferences.
2. **Review what will move.** Each row states the target app and exact scope.
   Safe local data starts selected. Credentials need separate consent. So do private keys.
3. **Prepare.** Close apps as needed, fetch files from the cloud, check space, and stage a resumable plan.
4. **Try Linux inside Windows.** Start the persistent VM before native boot.
   Show the same plan on Linux at first login.
5. **Finish setup.** Import into compatible apps. Offer direct sign-in or repair actions for unresolved rows.
6. **Choose independence later.** Copy shared files to Linux only when the user asks.
   Removal of Windows needs separate proof that no selected data depends on it.

Example preview:

| Item | Promise before migration | Result after migration |
|---|---|---|
| Photos | 4,812 local photos; keep Windows originals | Available from Windows, or copied and verified on Linux |
| OneDrive | 320 files need a download; 1.8 GB extra space on C: | 310 verified locally; 10 need attention |
| Edge | Bookmarks and history; sign in again for your account | Bookmarks imported; history needs the browser to close |
| Word | Documents and templates; macros need review | Files copied; 3 templates need a compatible app |
| Steam | Library locations and supported saves | Library linked; game compatibility and login remain separate |

A category can be partial. Do not collapse it into one green check.
“Available from Windows” must explain that the Windows disk remains required.
A missing app, denied consent, and failed scan are three distinct outcomes.

## Adapter coverage and order

| Priority | Adapter family | Data and configuration to cover | Boundaries and proof |
|---|---|---|---|
| P0 | Personal files | Known Folders, redirected Desktop/Documents/Pictures, Downloads, external folders, photo metadata, playlists | Resolve actual paths; preserve originals; verify bytes; report unreadable, encrypted, and cloud-only files |
| P0 | Browsers | Every selected profile; bookmarks, history, custom search, dictionary, open-tab export, compatible preferences | Explicit source-to-target mapping; version checks; no raw overwrite of an active profile; extensions by supported IDs |
| P0 | Desktop access | Locale, keyboard, time zone, wallpaper, text size, high contrast, pointer preferences | Translate supported intent per GNOME/KDE target; never promise identical Windows registry behavior |
| P0 | Connectivity | Personal Wi-Fi and simple proxy settings | Consent for secrets; NetworkManager helper; retain usable network fallback; enterprise 802.1X is a separate adapter |
| P1 | Mail and calendars | Thunderbird profiles, local mail archives, address books, ICS, account descriptions | Copy to a separate profile; app-open proof; Outlook PST/OST needs an explicit supported conversion or export path |
| P1 | Office | Documents, templates, dictionaries, user fonts, autocorrect where compatible | Keep originals; font-license checks; macro/add-in differences visible; representative document-open checks |
| P1 | Games | Steam libraries, per-game saves, launcher records, screenshots, controller preferences | Resolve local/cloud conflicts; Linux-native and Proton save paths differ; no blanket playability claim |
| P1 | Creative work | OBS scenes, media paths, VLC playlists, GIMP/Krita projects and compatible presets | Resolve referenced files; detect missing fonts/codecs/plugins; verify in target app |
| P1 | Developer tools | VS Code settings/keymaps/snippets/extensions, Git config, repositories, terminal profiles, WSL dotfiles | Translate paths; preserve uncommitted work; preview hooks and executable shell config; keys opt-in |
| P1 | Password managers | Vendor-supported vault export/import or sync setup | Prefer protected formats; never leave plaintext exports; passkeys and hardware-bound credentials may need re-enrollment |
| P2 | Devices | Printers, scanners, VPN connections, certificates, accessibility tools | Inventory plus known target support; drivers and device-bound private keys do not copy as ordinary files |
| P2 | Business apps | App-specific exports, domain settings, mapped shares, managed browser policy | Organization-approved adapter, policy provenance, user SID mapping; see enterprise spec |
| P2 | Unsupported Windows apps | App inventory, user-created data, known alternatives, optional runtime recipe | Label compatibility as unknown until tested; never call a package suggestion an application migration |

Priorities select testable slices. They are not promises of existing support.
Start with files and an adapter for one browser on one supported target.
Expand by observed user needs and retained compatibility evidence.

## Separate source format from target platform

A source adapter produces a portable intermediate record.
An adapter for the target resolves the app package and imports that record.
A distro profile chooses approved target apps and adapters by digest.
The source adapter must not hardcode Fedora, GNOME, a home path, or Flathub.

| Layer | Responsibility |
|---|---|
| Source adapter | Detect source version and profiles; export selected data in the correct Windows user context |
| Portable record | Data, typed preferences, logical file references, provenance, and unresolved capabilities |
| Target adapter | Resolve native/Flatpak/Snap paths and versions; transform, merge, validate, and undo |
| Supervisor | Consent, trust, budgets, dependency order, transactions, durable results, and privileged helpers |
| Distro profile | Package/ref/channel choice, desktop mappings, supported adapter digests, help links |
| UI | Plain-language previews, choices, progress, unresolved items, and retry/undo controls |

For example, Edge bookmarks become a bookmark tree with source IDs.
Firefox and Chromium importers consume that tree through different target formats.
Existing bookmarks remain intact. Retry deduplicates by stable IDs and content.

Flatpak uses app-specific paths and permissions. A copy to `~/.config`
can miss the real app profile. Resolve the installed app before the import.
See the [Flatpak conventions](https://docs.flatpak.org/en/latest/conventions.html).

## Proposed version-2 contract

Read version-1 manifests through a legacy adapter.
Do not reinterpret version-1 success as verified completion.
Publish version-2 schemas before third-party authors depend on this proposal.

| Contract field | Required meaning |
|---|---|
| `id`, `version`, `apiVersion`, `bundleDigest` | Stable lower-kebab-case ID; exact implementation and API version |
| `sourceSupport`, `targetSupport` | Tested app versions, store formats, architectures, package variants, desktops |
| `capabilities` | Data types and transformations; credential access declared separately |
| `readScopes`, `writeScopes`, `helperActions` | Logical approved paths and privileged operations; enforced by supervisor |
| `consentScopes` | Independent choices for ordinary data, history, sessions, credentials, private keys |
| `dependencies`, `conflicts` | Required capabilities and ownership of target resources; cycles fail before changes |
| `limits` | Time, memory, process count, output size, temporary storage, and allowed network use |
| `validation` | Observable postconditions and supported evidence types |
| `undo` | Undo scope, retention, and conditions that prohibit automatic rollback |

Lifecycle: `detect → plan → export → import → verify → commit`.
`resume`, `cancel`, and `undo` act on the same durable transaction.
Detection is read-only. The plan step is a dry run with no hydration or package install.

Export runs before Windows exits if the source needs a live user or app API.
The deployer can copy a sealed record. It does not execute plugins.
Import runs in the target user's session after the required app exists.

Every response includes protocol version, request ID, profile ID, plugin digest,
and structured errors. Logs cannot contain secrets. Bound every output stream.
Reject a mandatory capability if its meaning is unknown.
Do not allow a plugin response to grant itself new privileges.

Example of a proposed result:

```json
{
  "apiVersion": 2,
  "planId": "plan-0042",
  "profileId": "profile-0001",
  "pluginId": "browser-bookmarks",
  "pluginDigest": "sha256:<verified-bundle-digest>",
  "itemId": "edge-default-bookmarks",
  "state": "verified",
  "mode": "copy",
  "requestedCount": 124,
  "verifiedCount": 124,
  "evidence": [{"kind": "target-readback", "ref": "evidence/item-0042.json"}],
  "retryable": false,
  "sourceStillRequired": false,
  "undoRef": "transactions/item-0042"
}
```

The supervisor owns the ledger and validates evidence references.
A plugin cannot write an arbitrary path or assert a verified state by itself.
Evidence references stay inside the transaction; reject symlinks and traversal.
No raw username, URL history, or file contents belong in a fleet summary.

| State | Meaning in the UI |
|---|---|
| `discovered` | Found on Windows; not yet selected or moved |
| `scan_failed` | Could not inspect this item; it may still contain data |
| `not_present` | A successful scan found no item |
| `unsupported` | Found, but this source/target combination lacks a supported importer |
| `planned` | Selected with known prerequisites and a space estimate |
| `staged` | Export available; target import still owed |
| `imported_unverified` | Import returned; target checks still owed |
| `verified` | Requested postconditions passed; display the scope of those checks |
| `partial` | Some selected subitems passed; enumerate the rest |
| `needs_action` | Close an app, unlock a store, provide a file, or sign in |
| `failed`, `cancelled`, `skipped` | Distinct terminal or retryable outcomes with a reason |
| `rolled_back` | Undo checks passed; this does not undo later user edits |

Exit zero is not evidence of imported data.
A checksum proves bytes; it does not prove that an app can use them.
Login needs a separate live check with consent or remains “sign in once.”

## Transactions, conflicts, and recovery

Bind each plan to the Windows SID, profile path identity, source volume,
selected items, consent revision, target user, and adapter digests.
Revalidate the binding after reboot. Never substitute the UAC administrator's profile.
If the source fingerprint is stale, rescan or show a conflict.

Stage to a private directory on the target filesystem.
Record a journal before each mutation. Verify staged output before atomic replacement.
Keep a copy of the prior target if replacement is necessary and enough space exists.
Prefer a separate imported profile to replacement of an active profile.

If no safe backup fits, defer that item. Do not overwrite it.

A retry uses the same item IDs and fingerprints. They do not duplicate bookmarks or imports.
A resume after power loss reconciles the journal with the actual target files.
Undo touches only files the transaction still owns and whose fingerprints match.
If the user made later edits, show a conflict or offer an export. Do not delete those edits.

If a plugin fails, continue with independent items.

Use a supported backup API for a locked SQLite database, or close the app.
Never copy a live database without its WAL.
Test case collisions, Unicode normalization, long paths, sparse files, links,
NTFS alternate streams, EFS, and unreadable ACLs explicitly.
Keep source data that has no importer and report its location.

## Space and performance on older PCs

Keep separate budgets for Windows hydration, staged exports, target import,
transaction backups, and Linux root allocation. Deduplicate objects from a shared source.
Check available bytes on each actual volume, not the nominal `root.disk` size.
The size of a cloud placeholder does not prove that the bytes exist locally.
Read selected cloud files after hydration, then test access offline.

Scan metadata first. Calculate expensive sizes or hashes with bounded workers.
Default to one disk-heavy import at a time on rotational disks.
Pause optional work on battery or metered networks and offer a visible resume.
Use chunked copy, bounded memory, and durable checkpoints for large files.

Proposed test budgets: 2 CPU cores, 4 GB RAM, slow disk, 1366×768 display.
Measure startup, scan time, peak memory, and cancellation latency before setting release limits.

## Trust, credentials, and extension delivery

The first runner loads only reviewed adapters from the immutable image.
External discovery must be an explicit policy capability, disabled by default.
Do not let a user directory or environment variable shadow a trusted built-in.
A third-party bundle needs a trusted signer, immutable digest, API compatibility,
capability review, revocation status, and test evidence.
A signature identifies the publisher. A sandbox limits what the code can do.

Run adapters as the selected user with source access read-only and writes scoped.
System changes use narrow core helpers. Do not execute a plugin as root.
The supervisor installs packages from the distro's approved sources.
Deny network access unless the step needs it and the user approves.
Do not fetch and execute new plugin code during an elevated install.

Treat tokens, browser history, Wi-Fi secrets, and SSH keys as distinct consent scopes.
Use the original Windows user's unelevated collector for supported credential APIs.
Do not bypass app-bound encryption or device-bound keys.
Chrome has app-bound protection. Access through DPAPI does not prove that a session is portable;
see [Google's design note](https://security.googleblog.com/2024/07/improving-security-of-chrome-cookies-on.html).
Prefer a supported sync service, a protected export, or a guided re-link when needed.

Encrypt transport per user and bind envelopes to the plan, adapter, and target.
Document the actual unlock contract before any credential export is enabled.
Expire abandoned envelopes and remove them after verified import or cancellation.
Do not promise secure erasure of bytes on SSDs. Minimize retention and destroy keys.
Credential cleanup has its own result, including failure and retry.

Enterprise AD/SSSD/FreeIPA enrollment is a privileged core capability.
An adapter for an app cannot join a domain or create an identity mapping.
Use the [enterprise proposal](enterprise-migration.md) for policy and fleet controls.
Home users see none of those controls unless an organization manages their device.

## WinUI and Linux UI contract

Both UIs consume the same plan and ledger; they must not infer migration from logs.
Proposed engine methods: `ScanMigration`, `GetMigrationPlan`, `SetMigrationSelection`,
`PrepareMigration`, `GetMigrationResults`, `RetryMigrationItem`, and `UndoMigrationItem`.
The current `serve` protocol does not expose these methods.
Version these methods and generate DTOs before adoption in either UI.

The native shell needs six product states: scan, review, prepare, install,
finish-on-Linux, and recovery. These need not be six separate windows.
Keep advanced item choices behind Details. Preserve keyboard and screen-reader access.
Brand tokens, icons, support links, and human-readable outcome labels apply to both UIs.
CSS customization needs an explicit native equivalent or a documented limitation.

The Linux GTK tools remain the place to import, verify, retry, and sign in.
The Windows shell can show Windows-side preparation and later read returned evidence.
It must not say “migration complete” merely because Linux installation finished.

Retain the headless and legacy paths until WinUI has its own full-cycle proof.
Screenshots from Wails do not prove accessibility or interaction in WinUI.
Carry engine/storage evidence only if the tested code and contracts have no changes.
Repeat brand, UAC, cancel, recovery, upgrade, offline, and uninstall UI tests.

## Delivery sequence and acceptance gates

| PR slice | Deliverable | Gate |
|---|---|---|
| 1 | Correct wrapper reports and scanner error outcomes; reconcile discovery policy | Missing helper, failed helper, no source, denied selection, stale ledger all stay non-success |
| 2 | Version-2 plan/result schemas, supervisor journal, legacy adapters | Contract fixtures; malformed messages; crash/resume; no credential data in logs |
| 3 | Personal files plus browser bookmarks vertical slice | Windows export → Linux import → target readback → retry → undo; source unchanged |
| 4 | WinUI scaffold, valid elevation transport, brand resources, preview package | Native CI build; standard-user and alternate-admin UAC; offline launch; engine death/reconnect |
| 5 | Shared migration preview/results in WinUI and GTK | Identical fixture outcomes; large text, keyboard, screen reader; partial failure is visible |
| 6 | Mail, Office, games, preferences, cloud hydration adapters | Per-app version/packaging matrix; low disk, lock, conflict, cancellation, power loss |
| 7 | Supported credential paths | Consent, target unlock, real app checks, cleanup and revocation; no token-copy assumption |
| 8 | Distro and enterprise extension distribution | Digest/signature/policy enforcement, revoked bundle refusal, scoped helper tests |
| 9 | Native release cutover | Full native GUI Windows → Linux → Windows proof, recovery and uninstall; one legacy fallback release |

Use Corral/KubeVirt snapshots at pre-scan, post-export, pre-import, and post-import.
Seed synthetic accounts, files, profiles, and faults; never real user credentials.
Snapshots speed diagnosis, but include a fresh-run test that has no hidden prior state.
Retain source hashes, plan/result JSON, target readback, screenshots, and return-to-Windows proof.
Mutation tests must fail if the copy, target write, verifier, or consent gate is disabled.

A green result needs proof for the selected item. VM liveness and exit codes are not enough.
