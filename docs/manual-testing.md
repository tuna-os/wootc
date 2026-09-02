# Manual testing on a real machine

wootc is exercised nightly by an automated matrix of real Windows VMs, but
a VM is not a laptop: virtual ethernet, virtual firmware, no vendor OEM
partitions, no years of accumulated Windows. This is the pre-flight for
trying wootc **interactively on real hardware** — five minutes that make
the attempt safe and the feedback actionable.

wootc's whole design is reversibility (everything lives in `C:\wootc`, no
repartitioning, Windows stays the default boot), so the blast radius is
deliberately small. Treat it as alpha software anyway.

## Before you start

1. **Have a backup of anything you can't lose.** wootc doesn't touch your
   files — and you should never test alpha boot software without one.
2. **Know your BitLocker recovery key** (Settings ▸ Privacy & security ▸
   Device encryption, or `manage-bde -protectors C: -get`). On the beta
   channel, BitLocker-encrypted systems are supported: the installer leaves
   `C:` fully encrypted and sets up Linux on an unencrypted partition (or
   another volume), capturing the numerical recovery key to unlock `C:`
   read-only during profile migration. If firmware boot order changes
   trigger BitLocker recovery when booting back to Windows, entering your
   48-digit numerical recovery key once unlocks the drive and restores normal
   Windows startup. Have the key *before* rebooting, not after.
3. **Plug in the power adapter.** The app refuses to start on battery; the
   deploy boot can take 30–60 minutes on a slow connection.
4. **Check free disk**: 35 GB+ free on `C:` (20 GB minimum for Linux plus
   the 15 GB headroom the app reserves for Windows). The slider won't offer
   more than fits.
5. **Wired network beats Wi-Fi** for the *generic* `wootc.exe`: the deploy
   boot has no Wi-Fi. On a Wi-Fi-only laptop use a **branded installer**
   (or set `WOOTC_PRELOAD=1` before launching) — it downloads the whole OS
   while still on Windows, and the deploy boot then needs no network at
   all.
6. **Let it manage Fast Startup and hibernation.** The app turns them off
   during install (and the uninstaller restores your original setting) —
   don't re-enable them mid-test.

## What a good run looks like

1. **Windows, in the app**: pick an image, set a password, Install. The
   progress list narrates every step; the shield strip tells you what has
   actually changed at any moment. Reboot when asked (save other work
   first — the restart is forced).
2. **The deploy boot**: a calm splash screen ("Your Windows and all of your
   files are safe"), progress bar, 5–15 minutes on a fast line (the splash
   says so honestly if it will be longer). No scrolling text — that only
   appears in debug/E2E runs. It ends with "All set!" and reboots.
3. **First Linux boot**: the boot menu shows your distribution *and*
   Windows. Linux starts, you log in with the password you set, a welcome
   opens the "Bring over from Windows" dashboard, and your Windows folders
   are bridged (look for the "Windows drive" bookmark in the file manager).
4. **The way back**: reboot → Windows starts by default. In Windows, the
   app's Manage screen offers "Restart into <your distro>" whenever you
   want Linux again — and Uninstall puts everything back.

## If something goes wrong

Nothing before the reboot leaves more than the `C:\wootc` folder and (late
in the pipeline) one one-time boot entry — and a failure or cancel removes
the boot entry again. A failed deploy boot returns to Windows by itself
after 30 seconds.

Collect, in this order, and attach to a GitHub issue:

| What | Where |
|---|---|
| Installer log + state | `C:\wootc\logs\`, `C:\wootc\install\state.json` |
| Deployer log (the deploy boot writes it back) | `C:\wootc\logs\deployer.log` |
| Deployer journal snapshot | `C:\wootc\logs\deployer-last-journal.log` |
| What the screen said | a phone photo beats a memory |

Then run the uninstaller (Windows ▸ Settings ▸ Apps ▸ "TunaOS (wootc)", or
`wootc.exe uninstall`): it removes the boot entry and ESP files, restores
your Fast Startup/hibernation settings, and keeps `root.disk` unless you
tick otherwise — so a fixed build can retry without re-downloading.

## Debug mode

Add `wootc.debug` to the deployer's GRUB entry (press `e` in the boot menu)
to keep verbose consoles and get a shell instead of the auto-return on
failure. This is the observed/E2E behavior; normal runs stay calm on
purpose.
