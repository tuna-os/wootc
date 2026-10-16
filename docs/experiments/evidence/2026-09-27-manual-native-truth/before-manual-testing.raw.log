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
3. **Plug in the power adapter.** The app opens on battery but will not let
   you start the install until you plug in ("Plug in the power adapter
   first"); the deploy boot can take 30–60 minutes on a slow connection. A
   desktop with no battery at all is never blocked by this.
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
   app's Manage screen offers "Restart into `<your distro>`" whenever you
   want Linux again — and Uninstall puts everything back.

## If something goes wrong

Nothing before the reboot leaves more than the `C:\wootc` folder and (late
in the pipeline) one one-time boot entry — and a failure or cancel removes
the boot entry again. A failed deploy boot returns to Windows by itself
after 30 seconds.

Collect, in this order, and attach to a GitHub issue. The
[real hardware test report form](../.github/ISSUE_TEMPLATE/manual-test-report.yml)
asks for each item and records the machine details needed to triage it:

| What | Where |
|---|---|
| Installer log + state | `C:\wootc\logs\`, `C:\wootc\state.json` |
| Deployer log (the deploy boot writes it back) | `C:\wootc\logs\deployer.log` |
| Deployer journal snapshot | `C:\wootc\logs\deployer-last-journal.log` |
| What the screen said | a phone photo beats a memory |

Then run the uninstaller (Windows ▸ Settings ▸ Apps ▸ "TunaOS (wootc)", or
`wootc.exe uninstall`): it removes the boot entry and ESP files, restores
your Fast Startup/hibernation settings, and keeps `root.disk` unless you
tick otherwise — so a fixed build can retry without re-downloading.

## Proving the uninstall put everything back

"One uninstall puts everything back" is a v1.0 criterion ([#238]). On real
hardware, this is where machines are most different. Each vendor has its own
firmware boot entries. A dual-boot machine also has files on the ESP that
belong only to their owner.

The failures to find here are **silent**. Examples are an entry that stays,
hibernation that stays off, or an ESP file of a different owner that is gone. To see them,
you need a baseline, and **the uninstall itself deletes it**. So capture the
baseline first:

```powershell
# After the install completes, BEFORE uninstalling (run as Administrator):
.\tests\field\verify-uninstall.ps1 capture -Out C:\uninstall-proof
```

This command records:
- The firmware boot entries.
- Each ESP file, with its SHA-256.
- The ESP ownership manifest.
- Your live power settings.
- `C:\wootc` and the Add/Remove entry.

It also copies out `C:\wootc\install\prior-power.txt`. In this file, the
installer records the hibernation and Fast Startup values from *before* it
changed them.

Uninstall, reboot **two times**, then run:

```powershell
.\tests\field\verify-uninstall.ps1 verify -Baseline C:\uninstall-proof -RootDisk keep
```

The command shows a checklist and writes it to
`C:\uninstall-proof\checklist.md`. For each box, the checklist shows the
result *and the evidence for it*. The command **exits with a non-zero code if
a box fails**. Attach that file to your report. [#238] asks for this file.

The script does not change the machine under test. It writes only its own two
files into the folder that you name. The only other change is a temporary
drive letter for the ESP. The script removes that letter before it stops.

The checks:

| Box | How it is decided |
|---|---|
| Firmware boot entries clean | `bcdedit /enum firmware` no longer lists any wootc entry (the captured identifiers are named, so you can see what went) |
| ESP: every wootc-claimed file gone | each path in `EFI\wootc\wootc-owned.txt` is absent |
| ESP: nothing else touched | every other file is still there **and byte-identical** — a name-only diff would miss a rewrite |
| Hibernation / Fast Startup restored | current values match the recorded pre-install ones. A value that was *off* must still be off; restore is not "turn on" |
| `C:\wootc` state | judged against the choice you made — see below |
| Add/Remove Programs entry gone | the `Uninstall\wootc` key is unregistered |
| Windows booted clean twice | boot events since the capture, with no bugcheck or unexpected shutdown |

**`C:\wootc` is not always meant to disappear.** The default choice is to
keep it. The Apps entry and a bare `wootc.exe uninstall` both use this choice.
Then the folder stays with `disks\root.disk` and your logs, and the uninstall
removes only `install\`. Use `-RootDisk delete` only if you ticked *"Also
delete my Linux data"*. A correct keep run fails if you grade it against
"the folder is gone". Do not record that ✘, because it is not a real failure.

**The variant with orphaned leftovers.** On one machine, also test the path
where you delete `C:\wootc` by hand *before* the uninstall. Capture the
baseline first on this machine too. The power record is in the folder that you
delete, so the capture is the only way to grade the power box. Then add
`-Orphaned` to the verify run.

[#238]: https://github.com/tuna-os/wootc/issues/238

## Debug mode

Add `wootc.debug` to the deployer's GRUB entry (press `e` in the boot menu)
to keep verbose consoles and get a shell instead of the auto-return on
failure. This is the observed/E2E behavior; normal runs stay calm on
purpose.

---

## Fresh-eyes usability protocol (Milestone M5.1 / 1.0 Criterion 1)

**Milestone**: [#213](https://github.com/tuna-os/wootc/issues/213) (v1.0.0) — criterion 1  
**Tracking**: [#236](https://github.com/tuna-os/wootc/issues/236)  
**Goal**: Prove a person who has never seen or used wootc completes download → install → Linux → files found → back to Windows using **only what is on screen**.

Automated E2E tests prove the software executes; developer runs prove it works for experts. This protocol proves that the user experience, copy, safety explanations, and visual affordances are self-explanatory to the target audience with zero external guidance.

### 1. Participant recruitment & target profile

- **Recruit**: $\ge$ 2 participants who have never used or seen wootc.
- **Target profile**: Curious, non-technical Windows users (everyday computer users; **not** software engineers, Linux sysadmins, or wootc contributors).
- **Test environment**: A real Windows machine (Windows 10 or 11) with a normal user profile, existing files on `C:`, and an active internet connection.

### 2. Facilitator rules (Zero instructions)

1. **The single briefing sentence**: Hand the participant the download URL and say only:
   > *"This installs Linux next to your Windows; try it."*
2. **Silent observation**: The facilitator must remain completely silent throughout the run.
3. **No coaching or prompting**:
   - Do **not** point at the screen, explain terms, or suggest what button to click.
   - If the participant asks for help (e.g. *"Is this safe?"*, *"What password do I enter?"*, *"How do I get back?"*), give only a neutral response: *"Do whatever you think makes sense based on what's on the screen."*
4. **Log every detail**: Note every hesitation ($\ge 5$ seconds), pause, confused expression, reread sentence, or misclick, paired with the exact screen where it occurred.

### 3. Core participant journey & tasks

The participant must attempt and complete four core tasks unaided:

1. **Install**: Download the binary, launch it, navigate settings (distribution choice, password, disk size), start installation, and initiate the reboot when prompted.
2. **Linux first boot & file access**: Boot into Linux, log in with the credentials they configured, encounter the welcome / migration dashboard, and locate and open a familiar file from their Windows profile (via the User Data Bridge / "Windows drive" bookmark).
3. **Return to Windows**: Restart the computer and successfully return to the Windows desktop.
4. **Removal discovery**: In Windows, find how they would remove wootc / uninstall Linux if they wanted to reclaim disk space (e.g. Windows Settings ▸ Installed apps, Start menu, or app Manage screen).

### 4. Observation ledger template

Record observations using the following structure and attach the results to [#236](https://github.com/tuna-os/wootc/issues/236):

| Stage / Screen | Target outcome | Observed action & hesitations | Finding type (Blocker / Friction / Note) |
|---|---|---|---|
| **Download & launch** | Downloads exe, navigates SmartScreen/UAC calmly | | |
| **Launchpad & settings** | Understands disk/safety guarantees, sets password, clicks Install | | |
| **Deploy boot splash** | Waits through reboot and progress screen without panic | | |
| **First Linux login** | Logs into Linux desktop, notices Welcome / migration guide | | |
| **Windows file access** | Finds and opens known file via Windows drive bookmark | | |
| **Return to Windows** | Reboots back to Windows desktop unaided | | |
| **Uninstall discovery** | Identifies how to uninstall / remove wootc | | |

### 5. Exit criteria & triage

The fresh-eyes usability gate is satisfied when:

1. **Two observed runs complete unaided** from download through Windows return and uninstall discovery.
2. **Zero blockers remain**: Any issue that prevents a participant from completing the journey without facilitator intervention is a 1.0 blocker and must be fixed.
3. **Every hesitation triaged**: Every noted hesitation, confusing copy passage, or awkward interaction has either:
   - a linked GitHub issue filed to refine copy or workflow; or
   - an explicit maintainer won't-fix note with justification recorded in [#236](https://github.com/tuna-os/wootc/issues/236).

