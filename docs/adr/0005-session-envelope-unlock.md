# ADR 0005 — Explicit, memory-only session-envelope unlock

- **Date:** 2026-11-02
- **Status:** Proposed contract. This document describes the boundaries of the source; a maintainer must still approve the contract (#252). An agent cannot approve the contract. This document does not assert that live authentication passed.
- **Scope:** Unlock of Windows session envelopes with consent at first login on the target. This is not general unlock of Linux secret stores or verification of service login.

## Context

Windows will export envelopes with app-bound AES-256-GCM and the password for Linux installation.
The vault retains only a password hash.
Neither that hash nor the new Linux session can recover the original plaintext.
A separate, durable, reversible password/key for automatic unlock would add a credential and change the threat model.

A source os_crypt key is not a complete migrated session.
Identity in the Linux secret store, browser database formats, app package type and
invalidation by the live service remain independent requirements.
See [session migration](../session-migration.md).

## Decision

1. For each import, the dashboard asks for the **original installation password**
   and explicit **per-app consent**.
   It also asks for source/target profile, installed target package type and secret-store backend.
   Defaults do not authorize movement of tokens without explicit consent.
   Do not assume the current Linux password has not changed.
2. Submit the secret only with that action.
   Do not retain it in application state, settings, vault, ledger, logs, environment, command-line arguments, or a helper file.
   Clear mutable password/key buffers promptly.
   Managed immutable strings prevent a guarantee of complete memory erasure.
3. Discover only regular files with fixed names beneath
   `/run/wootc/host/wootc/install/slurp/session`: `exports.json` and
   `chrome.enc`, `edge.enc`, `spotify.enc`.
   Accept only a `staged` record for an eligible, supported app; ignore a claimed source `imported` state.
   Reject duplicate entries for supported apps, links, changed/oversized inputs, invalid versions,
   failures of app-bound GCM authentication and non-32-byte payloads.
   There is no installed `/usr/share` copy or fallback to arbitrary envelope paths.
4. A wrong password, damaged envelope or unsupported version causes a safe refusal that does not expose the secret.
   Leave the NTFS source and its staged ledger unchanged.
   Allow another explicit try; do not cache the secret or invent a durable lockout policy.
5. Cancel before submission closes the form without import.
   During submission, the modal disables Cancel/Escape.
   Shutdown/context cancellation and time limits apply; the modal promises no in-flight cancel control.
   Ordinary errors will request rollback.
   Browser activity, inode/identity, digest and sidecars of both the active store and restore candidate must still match.

   Rollback refuses unsafe, active or changed state and reports both recovery paths.
   It does not overwrite newer data.
   These observations are not a browser lease.
   A crash between stores can leave a partial format rewrite.
   The importer does not claim atomic recovery from a crash across stores.
   Never report signed-in success from such a state.
6. Unlock never marks a session imported or signed in and never deletes its source.
   A target format rewrite may record `rewritten` or `failed` in
   `~/.config/wootc/session-imports.json`, always unverified.
   Preserve native identities and all stores that the importer published or displaced, even after an otherwise clean rollback.
   Late writes through open file descriptors may reach those copies.
   Never automatically erase the published copies for recovery.
   Retain reported paths for manual recovery.

   Source envelopes remain encrypted on NTFS for retry; the importer does not automatically delete them.
7. Linux safeStorage needs the installed backend that the person explicitly selects and its existing unlocked Chrome identity.
   Do not fall back, generate secrets, activate services, or invoke unlock/prompt through Secret Service automatically.
   KWallet's native call to acquire a handle has a lock-after-check race that can cause a daemon prompt.
   Do not promise prompt-free operation.
   The importer will refuse an unsupported app identity or package type.
   It will offer normal sign-in/re-link instead.

## Alternatives rejected

- A durable installation password or reversible session-unlock secret would
  create another credential that an explicit action does not need.
- A key derived from the persisted password hash would not match the export format.
  It would let possession of the hash replace password knowledge.
- A guessed desktop secret store/backend or silent unlock risks the wrong identity and unwanted prompts.
  It also risks incompatible output and false success reports.
- A successful envelope/format operation does not measure acceptance by the destination app/service.
  Do not call that result "signed in".

## Consequences and acceptance

The person may need to re-enter an old installation password and unlock their secret store themselves.
A forgotten password or unsupported storage remains a normal sign-in/re-link outcome.
It does not justify weaker authentication of the source.
Encrypted originals and backups remain sensitive and need a separate, explicit decision about retention/deletion.
File removal does not prove physical erasure.

Acceptance still needs a maintainer to approve this contract.
It also needs tests in a real user session for correct/wrong password, retry, pre-submit and in-flight cancel.
Test refusal of locked/unavailable secret stores, safe source discovery, preserved destination content, multi-store rollback and crash/retry.
Test whether the UI shows truthful outcomes that persist after restart.

Before any separate signed-in state, get live launch/restart evidence with a disposable account.
No synthetic crypto/database fixture fulfills that authentication gate.
