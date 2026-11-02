# Session migration — staged keys, explicit import, honest outcomes

## Scope and evidence, 2026-11-02

The goal is to preserve a person's digital setup where safe and otherwise help
them sign in or re-link. **A copied profile, unlocked key, rewritten database,
or synthetic crypto fixture is not proof of a logged-in service.** Current
source implements bounded Chrome/Edge-source store rewriting into initialized
Linux Chrome profiles. The real disposable-account Chrome/Edge/Spotify
launch-and-restart matrix remains a separate gate (#296). Spotify's actual
session format and Linux safeStorage identity remain unsupported: sign in again.

This describes source behavior, not a promise that the older published
`v0.1.0-alpha.1` contains the target-side importer. See [getting started](getting-started.md)
and [verification status](status.md). The
[unlock ADR](adr/0005-session-envelope-unlock.md) records the explicit-password
contract; maintainer approval is still required for #252 acceptance.

## Ownership and consent

| Stage | Responsibility | What it does not prove |
|---|---|---|
| Windows online collector | Identify the original interactive user, assess DPAPI decryptability, export a consented per-app os_crypt key | Linux compatibility or accepted login |
| Deployer | Retain encrypted session envelopes on the Windows volume; do not install copies under `/usr/share` | Unlock or authentication |
| Linux dashboard | Ask for per-app consent and the original installation password for this attempt; invoke the target import action | Successful service login |
| Linux importer | Validate source/envelope/schema/keyring, prepare replacements, preserve existing identities and backups, record outcome | Live authentication, token validity, account/service acceptance |
| User/runtime acceptance | Open the actual app with a disposable account and check behavior after restart | A generic guarantee for other app versions or services |

Consent defaults off. Windows `InstallConfig.sessionConsent` opts in per app;
missing/false entries stage nothing. Linux target import requires a separate
explicit per-app consent action. Do not silently infer one from the other.
Native install-purpose RPC currently refuses `sessionConsent`: its strict
plan is not a session-export API. The legacy Windows path refuses when it
cannot establish the original interactive user or elevation changes that
identity; environment variables are not authority to decrypt another user's data.

## Windows envelope and discovery

The exporter stages only the DPAPI-recovered **32-byte os_crypt key**, not a
complete cookie database or token payload, at
`<drive>:\wootc\install\slurp\session\<app>.enc`. Its `exports.json` ledger
uses `staged`, `skipped` or `failed`, never authenticated/imported success.
Export is best-effort; failure must not be presented as a transferred session.

The envelope is versioned authenticated AES-256-GCM:
`[version | 32-byte salt | nonce | ciphertext + tag]`. HKDF-SHA256 derives the
key from the original Linux installation password, app name and fresh salt;
the app name is also associated data. The installer persists a password hash,
not recoverable plaintext. A later Linux login/password change does not change
which password opens an already staged envelope.

Target discovery is **only**:

```text
/run/wootc/host/wootc/install/slurp/session/
  exports.json
  chrome.enc
  edge.enc
  spotify.enc
```

The Windows source is read-only to the target importer. There is no fallback
to `/usr/share`, no arbitrary caller-selected envelope path and no recursive
scan. Only supported app names with a `staged` ledger entry are consumable;
a source ledger claiming `imported` is not evidence and is ignored. The ledger
is bounded to 64 KiB; each regular, non-symlink envelope is bounded to 4096
bytes. Duplicated supported app entries, changed/unsafe files, unsupported
versions, failed GCM authentication and non-32-byte payloads are refused.

## Unlock, retry, cancellation and cleanup

- Enter the **original installation password** explicitly for each attempt.
  It is not a Windows password or a request to unlock every Linux keyring.
  The dashboard must not prefill it from durable state.
- The password travels only in the in-process request, is not retained in
  `App` state, a ledger, logs, command-line arguments, environment, or a file.
  Mutable buffers are cleared after use. Go/JavaScript strings and garbage
  collection do not provide a provable complete-memory-erasure guarantee.
- Wrong password, damaged envelope and unsupported version share a safe unlock
  refusal; do not reveal or log secret material. The source stays `staged`
  and unchanged. The person may retry with a new password; there is no durable
  lockout counter or retry secret cache.
- Cancelling before submission closes the form without invoking import. While
  an import is submitted, the modal disables Cancel/Escape; there is no claimed
  in-flight cancel button. Process shutdown/context cancellation and bounded
  keyring work still apply. Do not report a partial operation as success or
  equate closing a form with observed worker cancellation. Keep rollback errors.
- Unlock alone never deletes the envelope or changes its source ledger. This
  importer leaves originals on NTFS for retry; it does not automatically wipe
  them after a rewrite. They remain sensitive encrypted material. Do not attach
  them, browser databases or keyring secrets to a public issue.

## Target action and supported formats

`App.ImportAppSession` takes this JSON-shaped Wails request (this is **not** a
new `wootc.exe serve` method and there is no shell unlock CLI):

```json
{"app":"chrome","consent":true,"password":"<entered for this attempt>","backend":"secret-service","packaging":"flatpak","sourceProfile":"Default","targetProfile":"Default"}
```

Treat this as an input schema, not a command to paste with a real password.
`app` is `chrome` or `edge` for supported rewriting; `spotify` returns re-link
advice without changing a profile. `packaging` is explicitly `flatpak` or
`native` for the initialized **Google Chrome** target:

- Flatpak: `~/.var/app/com.google.Chrome/config/google-chrome`
- Native: `~/.config/google-chrome`

Source and target profile names are `Default` or numbered `Profile N` names.
An Edge Windows source maps to the Chrome Linux target; this is not a claim
that arbitrary native/Flatpak Edge destinations or packaging identities work.
Open the target once, close all Chrome/Chromium processes, then import as the
installed user in their desktop session. Unsafe paths, a running browser,
singleton locks, missing/uninitialized profiles, concurrent imports and
unsupported packaging are refused; do not delete browser locks to bypass this.
The target must already contain a compatible Cookies database (schema 23/24)
and, when source Local Storage exists, its own `Local Storage/leveldb`
`VERSION=1` store. Opening an otherwise empty profile is not sufficient if
those stores do not exist. The importer never invents a destination schema or
automatically initializes a new database.

### Cookies SQLite

- Supports validated Chromium schema versions **23 and 24**, source Windows
  `v10` AES-GCM values and schema-24 domain binding. Windows app-bound `v20`,
  unknown schema/crypto prefixes and incompatible rows refuse rather than
  guess a decryption scheme.
- Re-encrypts imported values using the explicitly selected Linux keyring.
  Existing target cookie identities win; importing is not permission to
  overwrite native cookies or clear a signed-in target account.
- Stage into a complete replacement, retain the adjacent
  `.wootc-session-backup-*` original, and use atomic exchange. The source
  Windows database is never modified.

### Local Storage LevelDB

The supported Chromium `VERSION=1` store contains script-controlled bytes,
not a universal encrypted safeStorage value format. The importer merges
supported origin records **byte-for-byte**, preserving existing target
origins, instead of blindly decrypting every `v10`-looking value. Unknown
metadata/layout, corruption or locks refuse. Spotify/Electron record layout
and invalidation behavior are not inferred from generic Chromium fixtures.

A later store or outcome-ledger error requests rollback of already published
replacements during an ordinary running operation. Before publication or
rollback, the importer rechecks browser activity, file identity/inode,
content digest and database sidecars, including the backup it would restore.
If the browser becomes active or either store changes, rollback **refuses**
rather than overwriting newer data and reports both paths for manual recovery.

This is **not a browser lease or a crash-atomic multi-store transaction**:
a browser can race an observation, and a process/power failure between stores
can leave a partial format rewrite. All previously published/displaced stores
are retained, even after an otherwise clean rollback, because a late write
through an open file descriptor can still reach them. Do not automatically
erase these recovery copies or assume that one path contains every latest
write. Keep them private, stop the browser and inspect reported paths/errors
before manual recovery or retry. No signed-in state is produced.

## Linux safeStorage prerequisites and limitations

Select `backend` explicitly: `secret-service`, `kwallet5` or `kwallet6`.
There is no backend guessing, automatic fallback, new secret generation, or
Chromium `basic_text`/plaintext fallback. The importer uses the target Chrome
identity (including when the Windows source is Edge):

| Backend | Existing identity required |
|---|---|
| Secret Service | `application=chrome`, Chrome Safe Storage secret, in the existing unlocked default collection |
| KWallet 5/6 | Existing network wallet, folder `Chrome Keys`, key `Chrome Safe Storage`, application `Google Chrome` |

Run as the installed desktop user with a valid explicit
`DBUS_SESSION_BUS_ADDRESS`, an active permitted service and the existing
unlocked collection/wallet. The adapter does not activate a service or invoke
Secret Service Unlock/Prompt. Secret Service uses its standard `plain`
transport session on that user's D-Bus, not plaintext storage of the browser
secret. KWallet checks that the wallet is open before its required native
handle-acquisition call; a wallet locking between those calls is an unavoidable
race that can still cause a daemon prompt. Do not promise a no-prompt guarantee.

The target Flatpak must use that exact key identity and have the required
D-Bus access. Portal-only or isolated access is not assumed to be compatible.
Output uses Linux Chromium `v11` AES-128-CBC safeStorage with its documented
PBKDF2 parameters; that byte-format conversion is not proof of browser or
service acceptance. Spotify needs real versioned sanitized Linux/Windows
records and a verified safeStorage identity before support can be implemented.

## Detection, ledgers and presentation

`wootc-detect-apps --detect-browsers [username]` is the shared read-only browser
detector. It honors the standard `WOOTC_HOST`, `WOOTC_WIN_USER` and
`WOOTC_WIN_USER_DIR` source-selection contract; browser plugins, the manifest
fallback and the legacy app detector consume those records. Detection itself
does not copy browser data or change mount/user-directory setup.

Browser detection retains Firefox `profiles.ini` and Chrome/Edge `User Data`
discovery and source fields. UI outcomes remain `portable`, `staged` or
`signin`, with details. A source export's `staged` entry is eligibility, not
proof of authentication. Even an untrusted source `imported` marker must not
be displayed as signed in.

Target outcomes are recorded separately in
`~/.config/wootc/session-imports.json`: `rewritten` or `failed`, with
`verified:false`; Spotify is re-link-only. The action result includes `app`,
`state`, `verified`, `reason`, `cookiesWritten`, `localRecordsWritten`,
`recordsPreserved` and optional backup paths. The source export ledger stays
`staged`. Use wording such as **“Supported records rewritten; sign in if
requested”**, never **“Session moved”** or **“Signed in”** from that result.

Firefox whole-profile copies can include saved passwords, but still do not
prove every service accepts the new profile. Phone-linked apps should use
their own link-a-device flow. Discord/Slack remain sign-in/re-link routes;
a DPAPI key alone is not permission to transplant their credentials.

## Remaining runtime acceptance

Run on a disposable real Windows source account and a Linux graphical user
session, using real initialized Chrome/Edge stores, actual supported SQLite
versions and each required keyring/backend/packaging combination. Verify source
and target preservation, explicit consent, wrong-password retry, cancellation,
locked keyring refusal, duplicate identity/origin preservation, multi-store
rollback, and persistence of the outcome after restarting the dashboard.

For authentication acceptance, use a consented disposable service account,
open the real destination app, observe the expected account/content, quit and
restart it, and retain sanitized evidence tied to app version, backend,
packaging and build SHA. Record invalidated sessions as sign-in/re-link, not
migration success. Spotify remains blocked on real format/keyring fixtures.
Synthetic cookie, LevelDB or D-Bus tests cannot replace this matrix.
