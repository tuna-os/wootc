# E2E migration coverage

This page lists what wootc migrates from Windows and the code for each
capability. It also tells how the hosted E2E seeds each one on a real Windows
VM and checks it on the installed system. The hosted E2E is
`tests/e2e/run-e2e.sh`. It runs in the release gate's `bluefin:stable`
native-GUI Phase 1→2→3 cell and in the nightly.

The suite has these parts:

- `tests/e2e/oem/seed-profile.ps1`: the seed and the expected-state manifest.
- `tests/e2e/lib/migration.sh`: it stages the files, sets up Wi-Fi, runs the
  on-demand actions and records the results.
- `tests/e2e/migration-check.py`: the Linux-side checks. The guest agent runs
  them in Phase 2. `wootc-e2e-native-migration.service` runs them on the
  native disk.
- `tests/unit/test_migration_check.py`: the controls. Each comparison goes
  red on its regression.

Verdicts go into the run's result ledger as `migration-<phase>-<category>`
(`phase2`, `native`, `windows`). A `GAP` line is a capability that wootc
claims but does not have yet. The runner writes these lines to
`artifacts/<run>/migration-gaps.txt`. A `GAP` line never counts as a pass.

## Before this suite

The E2E put one file on Windows, `Documents\wootc-e2e-userdata.txt`. It
checked only that file, with two steps in `run-e2e.sh`: one in Phase 2 and
one on the native disk. `seed-profile.ps1` existed, but it had three problems:

- The runner staged it from a path that does not exist
  (`$SCRIPT_DIR/seed-profile.ps1`).
- The GUI path did not refresh `C:\OEM`.
- Its registry seed wrote the `HKCU` of SYSTEM, because QGA runs as SYSTEM.

No check read what it wrote.

## Inventory

Paths are relative to the repository. "P2" = Phase 2 (loop-mounted root.disk),
"P3" = native disk after `wootc-go-native migrate --to-disk`.

| Category | Implemented (where) | When | Seeded | Asserted P2 | Asserted P3 |
|---|---|---|---|---|---|
| Account: name, admin, password | `app/vault_windows.go:58` → `payload/deployer/deploy.sh` vault ingest (~987) + recipe `user` (~1571); P3 `wootc-go-native` graduate (~535) | deployer; P3 recipe | directive username/password | `account`: uid≥1000, owns home, wheel, `sudo -l` ALL, shadow hash verifies, real PAM `su` login as an unprivileged user + wrong password refused | same, on the native disk |
| Hostname | vault/cmdline → recipe `hostname`; P3 hardcoded `"wootc"` (bug) | deployer; P3 | directive `hostname` | `hostname` | `hostname` |
| Full name | claimed `payload/migration/wootc-identity`; never collected (`slurp/look.go` has no field) | — | — | GAP `account-fullname` | GAP |
| Account picture | `wootc-identity apply` from `wootc-mount-user-dirs` | P2 every boot | real PNG in `AccountPictures` | `identity-picture` (~/.face bytes), `identity-accountsservice` | `identity-picture` |
| Secondary Windows profiles → locked accounts | `deploy.sh` ~1779 | deployer | not seeded | — | — |
| Known folders (Documents, Pictures, Music, Videos, Desktop, Downloads) | `wootc-host-bind.service`, `wootc-mount-user-dirs` (binds), `wootc-copy-windows-documents` (BitLocker) | P2 every boot; P3 `rsync -aHAX /home` | corpus: nested dirs, unicode + emoji names, 0 B … 64 MiB, fixed old mtimes | `folders` (size, sha256, mtime, read as the user), `folders-bridge` (all six bound, user can write) | `folders` (+ owned by the user) |
| Windows volume from Linux | `/etc/wootc/host-view` (`payload/migration/wootc-host-view`) | P2 | canary | `windows-volume` (ro, `wootc/` masked, canary readable) | n/a (no Windows mount natively) |
| Convert a folder to native (stage 4) | `payload/migration/wootc-convert-dir` | on demand | Music corpus | `convert` (no bind, marker) + Music under `folders` | Music under `folders` |
| Office dictionary, templates, AutoCorrect | `wootc-office-bridge` → `lib/wootc_import_safety.py` `office()` | P2 every boot | CUSTOM.DIC, 3 templates, default.acl | `office-dictionary`, `office-templates`, `office-autocorrect` | same |
| Per-user fonts | same `office()` | P2 every boot | a real TrueType copy | `fonts` (bytes), `fonts-usable` (fontconfig lists it for the user) | same |
| App detection → Flathub IDs | `wootc-detect-apps` (AppData + `programs.json`) | P2 every boot | HKLM uninstall keys + AppData footprints | `apps-detected` (11 mapped IDs) | same report |
| App data: VS Code, Telegram, OBS | `wootc-detect-apps` `migrate()` | P2 every boot | settings/snippets/tdata/scenes | `apps-vscode`, `apps-vscode-extensions`, `apps-telegram`, `apps-obs` | same |
| Windows apps → Flatpak install | claimed SPEC §4.3; being implemented (deployer installs the user-confirmed IDs; shell opt-out) | deployer; P3 carries `/var/lib/flatpak` | Audacity, Inkscape selected; GIMP deselected | `apps-flatpak-install`: `flatpak info --system`, `flatpak run --command=true` as the user, deselected absent, receipt | same (no receipt) |
| Steam libraries | `wootc-steam-bridge` | P2 every boot | two libraries + VDF | `steam` (both found); GAP `steam-registered` until Linux Steam initialised | `steam` |
| Browsers (Chrome, Edge, Firefox) | `payload/migration/wootc-import-browser` | on demand only; no deployed UI reaches it for the internal disk (`wootc-import scan` excludes the boot disk) | Chrome/Edge Bookmarks+History, Firefox profile | `browsers-chrome`, `browsers-edge`, `browsers-firefox` after running the importer | same files |
| Wi-Fi | `app/slurp_windows.go` `collectWifi` → `deploy.sh` ~2474 → `wootc-wifi-import.service` → `wootc-wifi-bridge` | P1 export, P2 first boot | 4 netsh-format exports (WPA2-PSK, WPA3-SAE with unicode SSID, open, enterprise) at the collector's output (QEMU has no WLAN device for `netsh` to export from) | `wifi` (keyfile per network, key-mgmt, passphrase, 0600, NM loaded it, enterprise not imported), `wifi-cleartext` (no cleartext export left on Linux or NTFS), `wifi-connect` SKIP without `mac80211_hwsim` | `wifi` |
| Time zone | `collectLook` (only when Windows-Style Mode is on) → `deploy.sh` ~2612 | P1 + deployer | Tokyo Standard Time | `timezone` | `timezone` |
| Locale | collected (`slurp.json language`), never applied | — | de-DE language list | `locale` | `locale` |
| Keyboard | `wootc-apply-look` per user (GNOME/KDE/niri) | first login | de-DE | `keyboard` (system), `look-applied` (user input sources) | `keyboard` |
| Wallpaper, dark mode, accent | `collectLook` → `/usr/share/wootc/slurp` → `wootc-apply-look` autostart | P1 + first login | real JPEG wallpaper, dark, ColorizationColor 0xC4E62D42 | `look-collected` (Windows side), `look-applied` (autostart Exec run in the user's manager, gsettings read back) | — |
| Printers | claimed SPEC §4.6; no code | — | — | GAP `printers` | GAP |
| Windows-native SSH keys, git config | claimed SPEC (developer setup); only the on-demand WSL bridge copies them | — | `.gitconfig` | GAP `dev-ssh-git` | GAP |
| Cloud drives | disclosure only (`wootc-mount-user-dirs` journal) | P2 | — | — | — |
| BitLocker | `bitlocker_windows.go`, `wootc-mount-user-dirs` unlock + Documents copy | P2 | BitLocker nightly cell | existing BitLocker assertions; `folders` maps Documents to `Documents/From Windows` | — |
| Phase 1/2/3 transitions | `install_engine.go`, deployer, `wootc-go-native` | — | — | existing boot/lifecycle gates | existing native-boot + health gates |
| Windows coexistence | binds are read-write into the Windows profile | P2 | corpus | `migration-windows-intact` re-hashes every seeded file on Windows after the return (non-Phase-3 cells) | not re-entered after P3 |
| Uninstall / rollback | `installer_windows.go` `uninstallWith` | Windows | — | existing opt-in `uninstall_check` (non-Phase-3) | — |
| Upgrades | `wootc-esp-sync` after `bootc upgrade`; no app self-update | P2 | — | not covered | not covered |

## Gate runs

Two runs apply the checks above. One is the release gate's E2E
(`release.yml` → `e2e-hosted.yml`, `bluefin:stable`, `gui_install: true`,
`gui_frontend: native`, `phase3: true`). The other is the nightly.
`docs/RELEASING.md` gives the command for a probe run.
