# ADR 0005 — Explicit, memory-only session-envelope unlock

- **Date:** 2026-11-02
- **Status:** Proposed contract, implemented source boundaries documented; maintainer approval pending (#252). This document does not assert that an agent can approve the contract or that live authentication passed.
- **Scope:** First-login target-side unlock of the consented Windows session envelopes; not general Linux keyring unlock or service-login verification.

## Context

Windows exports app-bound AES-256-GCM envelopes using the Linux installation
password. The vault retains only a password hash. Neither that hash nor the
new Linux session can recover the original plaintext. Persisting another
reversible password/key solely to make this automatic would add a durable
credential and change the threat model.

A source os_crypt key is not a complete migrated session. Linux keyring identity,
browser database formats, app packaging and live-service invalidation remain
independent requirements. See [session migration](../session-migration.md).

## Decision

1. The dashboard asks for the **original installation password**, explicit
   **per-app consent**, source/target profile, installed target packaging and
   keyring backend for each import attempt. Defaults do not silently authorize
   token movement. Do not assume the current Linux password is unchanged.
2. Submit the secret only with that action. Do not retain it in application
   state, settings, vault, ledger, logs, environment, command-line arguments,
   or a helper file. Clear mutable password/key buffers promptly. Managed
   immutable strings mean complete memory erasure is not guaranteed.
3. Discover only regular fixed-name files beneath
   `/run/wootc/host/wootc/install/slurp/session`: `exports.json` and
   `chrome.enc`, `edge.enc`, `spotify.enc`. Require an eligible supported
   app's `staged` record; ignore a claimed source `imported` state. Reject
   duplicate supported entries, links, changed/oversized inputs, invalid
   versions, failed app-bound GCM authentication and non-32-byte payloads.
   There is no installed `/usr/share` copy or arbitrary envelope-path fallback.
4. A wrong password, damaged envelope or unsupported version yields a safe
   refusal without exposing the secret. Leave the NTFS source and its staged
   ledger unchanged. Allow another explicit attempt; do not cache the secret
   or invent a durable lockout policy.
5. Cancel before submission closes the form without import. During submission,
   Cancel/Escape are disabled; shutdown/context cancellation and bounded
   operations apply, not a promised in-flight cancel control. Ordinary errors
   request rollback, but browser activity, inode/identity, digest and sidecars
   of both the active store and restore candidate must still match. Unsafe,
   active or changed state refuses rollback and reports both recovery paths
   rather than overwriting newer data. These observations are not a browser
   lease. A crash between stores can leave partial format rewriting; atomic
   multi-store crash recovery is not claimed. Never report signed-in success
   from such a state.
6. Unlock never marks a session imported or signed in and never deletes its
   source. Current target format rewriting may record `rewritten` or `failed`
   in `~/.config/wootc/session-imports.json`, always unverified. Preserve native
   identities and all previously published/displaced stores, including after
   an otherwise clean rollback: late writes through open file descriptors may
   reach those copies. No automatic erasure of published recovery copies is
   permitted. Retain reported paths for manual recovery; source envelopes
   remain encrypted on NTFS for retry and are not automatically deleted.
7. Linux safeStorage requires the explicitly selected installed backend and
   its existing unlocked Chrome identity. No fallback, secret generation,
   service activation, or automatic Secret Service unlock/prompt. KWallet's
   native handle acquisition has a lock-after-check race that can cause a
   daemon prompt; do not promise prompt-free operation. Unsupported app identity
   or packaging refuses and offers normal sign-in/re-link instead.

## Alternatives rejected

- Persisting the installation password or a reversible session-unlock secret:
  creates another durable credential and is unnecessary for an explicit action.
- Deriving the envelope key from the persisted password hash: that is not the
  export format and would let possession of the hash replace password knowledge.
- Guessing the desktop keyring/backend or silently unlocking it: risks the wrong
  identity, unwanted prompts, incompatible output and misleading success.
- Calling a successful envelope/format operation "signed in": does not measure
  acceptance by the destination app/service.

## Consequences and acceptance

The person may need to re-enter an old installation password and unlock their
keyring themselves. Forgotten password or unsupported storage remains a normal
sign-in/re-link outcome, not a reason to weaken source authentication.
Encrypted originals and backups remain sensitive and require a separate,
explicit retention/deletion decision; unlinking does not prove physical erasure.

Acceptance still requires a maintainer to approve this contract and real-user-
session tests for correct/wrong password, retry, pre-submit and in-flight cancel,
locked/unavailable keyring refusal, safe source discovery, preserved destination
content, multi-store rollback, crash/retry and truthful restart-persistent UI.
Live disposable-account launch/restart evidence is required before any separate
signed-in state can be introduced. No synthetic crypto/database fixture fulfills
that authentication gate.
