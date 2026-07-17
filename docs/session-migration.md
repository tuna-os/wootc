# Session migration — copy the login where we honestly can, re-link where we can't

North Star: the user should not have to re-set-up their digital life. So
we try, in this order, to carry each app's *logged-in session* across —
and when we can't do it safely, we make re-authenticating one tap, not a
scavenger hunt.

## The key realization: decrypt in Windows, not in the deployer

Most "you can't migrate the session" folklore assumes offline access from
Linux. But the **wootc installer GUI runs inside the user's live Windows
session**, where the DPAPI master key is unlocked. That is exactly where
Chromium/Electron `safeStorage` and cookie databases *can* be decrypted.

So session handling splits by *where* it must happen:

| Where | What it can do | Owns |
|---|---|---|
| **Windows GUI (online, DPAPI available)** | decrypt cookies/tokens, re-encrypt for transport | `slurp_windows.go` session collectors |
| **Deployer (offline)** | copy plain-file state only | `wootc-detect-apps`, `wootc-import-browser` |
| **Target first-login** | re-import, or present a one-tap re-link | dashboard + `wootc-apply-look` |

## Per-class strategy

**Plain-file sessions → copy verbatim (already implemented).**
Firefox/Thunderbird whole profile, Telegram `tdata`, VS Code, OBS. These
carry the login with no decryption. Done in the deployer.

**Chromium/Electron `safeStorage` (Discord, Slack, Spotify, Chrome, Edge)
→ decrypt-and-rewrap in Windows.** At slurp time the GUI:
1. reads the app's `Local State`, DPAPI-decrypts the `os_crypt.encrypted_key`;
2. uses it to decrypt the Cookies/Local Storage LevelDB entries;
3. re-encrypts the payload under a key derived from the wootc vault
   secret (never written in clear to disk), stored in
   `install\slurp\session\<app>.enc`.
On the Linux side, the app's equivalent store is written back and
re-encrypted under the Linux `safeStorage` (libsecret/kwallet). Result:
the app opens already signed in. **Gated behind explicit user consent per
app** — this is moving auth tokens, so the dashboard asks first and
defaults off. (Implemented incrementally; the collector scaffolding lands
here, per-app LevelDB rewriting is the follow-up.)

**Phone-linked apps → guided re-link, not token theft.** Signal, WhatsApp,
and (when token copy is declined) any messenger: the safest, most durable
path is the app's own "link a device" flow. The dashboard shows the exact
steps and, where possible, deep-links the Linux app straight to its
QR/scan screen. This is *better* than copying a fragile token that the
service may invalidate on a new device fingerprint.

**Cloud-account apps → one-tap sign-in.** Spotify library, Discord
servers, Zoom — the content is server-side; a single sign-in restores
everything. The dashboard frames it that way ("your playlists are waiting
— just sign in") instead of implying data was lost.

## Honesty rules (non-negotiable, North Star)

- Never claim a session moved when only bookmarks did.
- Never silently copy auth tokens — always consent, always per-app.
- Prefer re-link over token copy when the service is known to invalidate
  transplanted sessions (avoids a broken-looking app on first launch).
- Every app row in the dashboard states its real outcome: *signed in*,
  *re-link needed (2 steps)*, or *sign in once*.
