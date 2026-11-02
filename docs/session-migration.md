# Session migration — staged keys, explicit import, honest outcomes

## Scope and evidence, 2026-11-02

The goal is to preserve a person's digital setup where safe. Otherwise, help
the person sign in or re-link.

**A copied profile, unlocked key, rewritten database,
or synthetic crypto fixture is not proof of a logged-in service.**

The source can rewrite supported stores from Chrome/Edge within strict bounds.
It targets profiles that Chrome has initialized on Linux.

The real disposable-account Chrome/Edge/Spotify launch-and-restart matrix remains
a separate gate (#296). Spotify's actual session format and Linux safeStorage
identity remain unsupported: sign in again.

This describes source behavior, not a promise that the older published
`v0.1.0-alpha.1` contains the target-side importer. See the [start guide](getting-started.md)
and [verification status](status.md). The
[unlock ADR](adr/0005-session-envelope-unlock.md) records the explicit-password
contract; a maintainer must still approve it for #252 acceptance.

## Ownership and consent

| Stage | Responsibility | What it does not prove |
|---|---|---|
| Windows online collector | Identify the original interactive user, assess DPAPI decryptability, export a consented per-app os_crypt key | Linux compatibility or accepted login |
| Deployer | Retain encrypted session envelopes on the Windows volume; do not install copies under `/usr/share` | Unlock or authentication |
| Linux dashboard | Ask for per-app consent and the original installation password for this attempt; invoke the target import action | Successful service login |
| Linux importer | Validate source/envelope/schema/keyring, prepare replacements, preserve existing identities and backups, record outcome | Live authentication, token validity, account/service acceptance |
| User/runtime acceptance | Open the actual app with a disposable account and check behavior after restart | A generic guarantee for other app versions or services |

Consent defaults off. Windows `InstallConfig.sessionConsent` opts in per app;
missing/false entries stage nothing. Import on Linux needs separate, explicit
consent for each app. Do not silently infer one from the other.

The native RPC for installation now refuses `sessionConsent`: its strict
plan is not a session-export API. The legacy path on Windows refuses if it
cannot establish the original interactive user. It also refuses if elevation
changes that identity. Environment variables do not grant authority to access another user's encrypted data.

## Windows envelope and discovery

The exporter stages only the DPAPI-recovered **32-byte os_crypt key**, not a
complete cookie database or token payload, at
`<drive>:\wootc\install\slurp\session\<app>.enc`. Its `exports.json` ledger
uses `staged`, `skipped` or `failed`, never authenticated/imported success.
Export is best-effort; the UI must not report a failed export as a transferred session.

The envelope uses versioned, authenticated AES-256-GCM:
`[version | 32-byte salt | nonce | ciphertext + tag]`. HKDF-SHA256 derives the
key from the original password for Linux installation, app name and fresh salt.
The app name is also associated data.
The installer persists a password hash, not recoverable plaintext.
A later Linux login/password change does not change which password opens an already staged envelope.

Target discovery is **only**:

```text
/run/wootc/host/wootc/install/slurp/session/
  exports.json
  chrome.enc
  edge.enc
  spotify.enc
```

The importer only reads the Windows source. It does not fall back to `/usr/share`,
accept an arbitrary envelope path from a caller, or scan recursively.
It consumes only supported app names with a `staged` ledger entry.
It ignores a source ledger that claims `imported`; that claim is not evidence.
The importer limits the ledger to 64 KiB and each regular, non-symlink envelope to 4096 bytes.

It refuses duplicate entries for supported apps, changed/unsafe files, unsupported
versions, failed GCM authentication and non-32-byte payloads.

## Unlock, retry, cancellation and cleanup

- Enter the **original installation password** explicitly for each try.
  It is not a Windows password or a request to unlock all Linux secret stores.
  The dashboard must not prefill it from durable state.
- The password travels only in the in-process request.
  The app does not retain it in `App` state, a ledger, logs, command-line arguments, environment, or a file.
  The code will clear mutable buffers after use.
  Go/JavaScript strings and garbage collection provide no guarantee of complete erasure from memory.
- Wrong password, damaged envelope and unsupported version share a safe unlock
  refusal; do not reveal or log secret material. The source stays `staged`
  and unchanged. The person may retry with a new password; there is no durable
  lockout counter or retry secret cache.
- Cancel before submission closes the form without import.
  After submission, the modal disables Cancel/Escape; it offers no in-flight cancel control.
  Process shutdown/context cancellation and time limits on secret-store work still apply.
  Do not report a partial operation as success.
  A closed form does not prove that the worker stopped. Keep rollback errors.
- Unlock alone never deletes the envelope or changes its source ledger.
  This importer leaves originals on NTFS for retry; it does not automatically wipe them after a rewrite.
  They remain sensitive encrypted material.
  Do not attach them, browser databases or secrets from credential stores to a public issue.

## Target action and supported formats

`App.ImportAppSession` takes this JSON-shaped Wails request (this is **not** a
new `wootc.exe serve` method and there is no shell unlock CLI):

```json
{"app":"chrome","consent":true,"password":"<entered for this attempt>","backend":"secret-service","packaging":"flatpak","sourceProfile":"Default","targetProfile":"Default"}
```

Treat this as an input schema, not a command to paste with a real password.
`app` is `chrome` or `edge` for supported rewrites.
For `spotify`, the action returns re-link advice and does not change a profile.
`packaging` is explicitly `flatpak` or `native` for the initialized **Google Chrome** target:

- Flatpak: `~/.var/app/com.google.Chrome/config/google-chrome`
- Native: `~/.config/google-chrome`

Source and target profile names are `Default` or numbered `Profile N` names.
An Edge source on Windows maps to the Chrome target on Linux.
This does not establish support for arbitrary native/Flatpak Edge destinations or package identities.
Open the target once, then close all Chrome/Chromium processes.
Import as the installed user in their desktop session.

The importer will refuse unsafe paths, active browsers, singleton locks, missing/uninitialized
profiles, concurrent imports and unsupported package types.
Do not delete browser locks to bypass this.
The target must already contain a compatible Cookies database (schema 23/24).
If the source has Local Storage, the target also needs its own `Local Storage/leveldb` `VERSION=1` store.
An otherwise empty profile does not suffice without those stores, even after you open it.
The importer never invents a destination schema or automatically initializes a new database.

### Cookies SQLite

- The importer supports validated schemas **23 and 24** for Chromium.
  It supports `v10` AES-GCM values from Windows and domain binding for schema 24.
  It refuses Windows app-bound `v20`, unknown schema/crypto prefixes and incompatible rows; it does not guess a decryption scheme.
- The importer will re-encrypt imported values with the Linux secret store that the person explicitly selects.
  Cookie identities that already exist in the target win.
  Import does not authorize changes to native cookies or removal of a signed-in target account.
- Stage into a complete replacement, retain the adjacent
  `.wootc-session-backup-*` original, and use atomic exchange.
  The importer never changes the source database on Windows.

### Local Storage LevelDB

The supported Chromium `VERSION=1` store contains script-controlled bytes,
not a universal format for encrypted safeStorage values.
The importer merges records for supported origins **byte-for-byte** and preserves origins that already exist in the target.
It does not blindly decrypt every value that resembles `v10`.
It refuses unknown metadata/layout, corruption or locks.
Generic Chromium fixtures do not establish Spotify/Electron record layout or invalidation behavior.

An error in a later store or the outcome ledger will request rollback of replacements
that the importer has already published during normal operation.
Before publication or rollback, the importer checks again for an active browser.
It also rechecks file identity/inode, content digest and database sidecars, with the same checks for the backup to restore.
If the browser becomes active or either store changes, rollback **refuses** to overwrite newer data.
It reports both paths for manual recovery.

This is **not a browser lease or a crash-atomic multi-store transaction**.
A browser can race an observation.
A process/power failure between stores can leave a partial format rewrite.
The importer retains all stores that it published or displaced, even after an otherwise clean rollback.
Late writes through open file descriptors can still reach those stores.

Do not automatically erase these recovery copies or assume that one path contains every latest write.
Keep them private and stop the browser.
Inspect reported paths/errors before manual recovery or retry.
The operation does not produce a signed-in state.

## Linux safeStorage prerequisites and limitations

Select `backend` explicitly: `secret-service`, `kwallet5` or `kwallet6`.
The importer does not guess a backend, fall back automatically, generate a new secret,
or use Chromium `basic_text`/plaintext fallback.
It uses the target Chrome identity, even when the Windows source is Edge:

| Backend | Existing identity required |
|---|---|
| Secret Service | `application=chrome`, Chrome Safe Storage secret, in the existing unlocked default collection |
| KWallet 5/6 | Existing network wallet, folder `Chrome Keys`, key `Chrome Safe Storage`, application `Google Chrome` |

Run as the installed desktop user with a valid, explicit `DBUS_SESSION_BUS_ADDRESS`.
Use an active, permitted service and the existing unlocked collection/wallet.
The adapter does not activate a service or invoke Secret Service Unlock/Prompt.
Secret Service uses its standard `plain` transport session on that user's D-Bus.
This does not store the browser secret as plaintext.

KWallet checks whether the wallet has an unlocked state before the native call to acquire a handle.
If the wallet locks between those calls, the unavoidable race can still cause a daemon prompt.
Do not promise a no-prompt guarantee.

The target Flatpak must use that exact key identity and have the required D-Bus access.
Do not assume compatibility with portal-only or isolated access.
Output uses Linux Chromium `v11` safeStorage with AES-128-CBC and its documented PBKDF2 parameters.
That byte-format conversion is not proof of browser or service acceptance.
Spotify support needs real, versioned, sanitized Linux/Windows records and a verified safeStorage identity.

## Detection, ledgers and presentation

`wootc-detect-apps --detect-browsers [username]` detects browsers and only reads their data.
It honors the standard `WOOTC_HOST`, `WOOTC_WIN_USER` and `WOOTC_WIN_USER_DIR` source-selection contract.
Browser plugins, the manifest fallback and the legacy detector for apps consume those records.
Detection itself does not copy browser data or change mount/user-directory setup.

Browser detection will retain discovery and source fields for Firefox `profiles.ini` and Chrome/Edge `User Data`.
UI outcomes remain `portable`, `staged` or `signin`, with details.
A source export's `staged` entry is eligibility, not proof of authentication.
The UI must not show signed-in status from even an untrusted source `imported` marker.

The importer will record outcomes for the target separately in
`~/.config/wootc/session-imports.json`: `rewritten` or `failed`, with
`verified:false`; Spotify is re-link-only. The action result includes `app`,
`state`, `verified`, `reason`, `cookiesWritten`, `localRecordsWritten`,
`recordsPreserved` and optional backup paths. The source export ledger stays `staged`.
Use text such as **“Supported records rewritten; sign in if requested”**.
Never report **“Session moved”** or **“Signed in”** from that result.

Firefox whole-profile copies can include saved passwords, but still do not
prove every service accepts the new profile. Phone-linked apps should use
their own link-a-device flow. Discord/Slack remain sign-in/re-link routes;
a DPAPI key alone is not permission to transplant their credentials.

## Remaining runtime acceptance

Use a disposable source account on real Windows and a graphical session on Linux.
Use real, initialized Chrome/Edge stores and supported versions of SQLite.
Test each required combination of secret store, backend and package type.
Verify source and target preservation, explicit consent, wrong-password retry and cancellation.
Verify refusal of locked secret stores, preservation of duplicate identities/origins, and multi-store rollback.
Verify that the outcome persists after a dashboard restart.

For authentication acceptance, get consent to use a disposable account for the service.
Open the real destination app and observe the expected account/content.
Quit and restart it.
Retain sanitized evidence that identifies the app version, backend, package type and build SHA.
Record invalidated sessions as sign-in/re-link, not migration success.

Spotify remains blocked on real fixtures for its format and secret store.
Synthetic cookie, LevelDB or D-Bus tests cannot replace this matrix.
