# wootc User Guide

wootc can install Linux in a disk file beside Windows.
The current installer prepares a native Linux boot after a restart.
The intended Phase 1 will run Linux inside Windows first.
That complete VM journey remains under development.

Windows remains the default boot choice during the native install path.
The installer changes boot entries, boot files, and Windows power settings.
Some storage choices also change partitions. Read the proposed plan before you continue.

This guide describes **current source**, not a guarantee that the latest
published tag contains every feature. On 2026-11-02 the observed latest
non-prerelease remained `v0.1.0-alpha.1`; main's native setup packaging is newer.
Follow [getting started](getting-started.md) for actual download names and
[current status](status.md) for evidence and limits.

## Contents

1. [Is my PC ready?](#1-is-my-pc-ready)
2. [Install Linux](#2-install-linux)
3. [First boot into Linux](#3-first-boot-into-linux)
4. [Bring your stuff over](#4-bring-your-stuff-over)
5. [Try it first, commit later](#5-try-it-first-commit-later)
6. [Import from another disk or a backup](#6-import-from-another-disk-or-a-backup)
7. [Encryption & BitLocker](#7-encryption--bitlocker)
8. [Go Linux-only](#8-go-linux-only)
9. [Uninstall](#9-uninstall)
10. [Problems and recovery](#10-problems-and-recovery)

## 1. Is my PC ready?

The app checks your PC at startup. Its current requirements include:

- **Windows 10 or 11**, 64-bit, with UEFI firmware.
- **Enough free space on an admitted storage volume.** The native plan needs a
  Linux disk of at least 20 GB **plus** image-dependent scratch, any offline
  image copy and a safety reserve. The app reads the reserve for the selected
  image and lowers the offered disk size to fit. A blanket "35 GB is enough"
  is not valid for every current image or frontend. VM preparation has a
  separate conservative 88 GiB host free-space gate; see [managed VM](managed-vm.md).
- **Secure Boot can remain on.** The installer checks whether your firmware trusts its Microsoft-signed loader before it changes boot configuration.
  It stops if it cannot confirm that trust.
- **BitLocker off for the alpha install path.** The released alpha refuses an encrypted Windows drive.
  You can wait for support; the installer does not decrypt Windows for you.
  See [§7](#7-encryption--bitlocker) for the experimental design.

You do not need a bootable USB for this path.

### Hardware warnings are not compatibility certificates

Current source assesses a staged image's Linux PCI module aliases before disk
or boot changes. A proven missing critical PCI driver can refuse the plan when
both Windows device inventory and one target kernel inventory are complete.
Nouveau-only graphics or firmware-framebuffer support gives a warning, not a
promise of an accelerated desktop. Missing declared firmware also warns:
Windows cannot establish which Linux firmware variant the device actually uses.
USB PnP identifiers lack a complete Linux modalias, so partial/unknown inventory
remains a warning rather than a fabricated match. Without a local/preloaded
image the assessment may be unknown. Neither unknown nor warning means green.
The detailed report is retained under the install root's
`bundle\hardware-report.json`; include it with a compatibility report.

<a id="2-install-linux-phase-1"></a>

## 2. Install Linux

Use an artifact actually present in the chosen release. The published older
generic executable is `wootc.exe`; current-source native packaging uses
`wootc-Installer-Setup.exe` (or a distribution-specific setup), which installs
the WinUI shell and protected engine. A native release may retain
`wootc-legacy.exe` for one release. The older Wails interface needs WebView2;
the native shell does not. These artifact generations are not interchangeable.

![Launchpad](screenshots/01-launchpad.png)

*Historical Wails/mock illustration, not a screenshot of the RC/native package.
No RC SHA is asserted for the retained image.*

1. **Pick a desktop.** The catalog has GNOME, KDE Plasma, Niri, and XFCE entries across several Linux bases.
   The selected brand and release channel determine the offered subset and
   default; a branded build need not default to Bluefin. See the
   [release policy](RELEASING.md#alpha-now).
2. **Set a password.** The app proposes your username, computer name, disk size, and encryption choice.
   Review them under **Advanced**. You can also change the Windows look option there.
3. **Review “Make it feel like Windows.”** Defaults differ between frontends;
   do not assume this box is selected. On supported Wayland desktops, the
   helpers transfer your selected wallpaper, accent, keyboard layout, and shortcuts.
   Saved Wi-Fi networks use a separate path.
4. Click **Install**. The app creates the Linux disk file and stages boot files.
   It also configures a one-time boot into the deployer and disables Fast Startup and hibernation.

![Install progress](screenshots/03-progress.png)

*Historical Wails/mock progress illustration; current native controls and RC
screenshots need their own retained evidence.*

Restart when you are ready. The one-time boot starts the deployer.
Windows remains the default after that entry expires.
A failed install can need recovery or cleanup. A one-time entry does not guarantee every failure returns safely.

<a id="3-first-boot-into-linux-phase-2"></a>

## 3. First boot into Linux

The deployer installs the chosen image into the disk file.
Windows normally returns after that one-time boot.
Open the app again. When the Manage screen offers **Restart into &lt;distro&gt; →**, choose it to schedule a Linux boot.

Linux then boots directly from the disk file on the Windows drive.
Its bootc image provides the installed system and update mechanism.
The boot files on the Windows ESP also need their own update checks.

The boot menu includes Windows. Native installation does not remove Windows.
On the KVM E2E rig, tests passed for some native cycles. See [current status](status.md) for their limits.

## 4. Bring your stuff over

Open **Bring Over From Windows** to review migration categories.
Some preferences can transfer automatically. Other imports need your choice.
Review each category's source, destination, and limits before you import it.

The helpers cover these categories:

- **Files:** Documents, Desktop, Pictures, Downloads, Music, and Videos.
  A folder can initially share its Windows contents. Conversion makes a separate Linux copy.
- **Browsers:** Firefox imports a complete profile, which can include saved passwords.
  Chrome and Edge can import bookmarks and history. Their encrypted Windows
  stores and login tokens have separate consent, keyring and service-specific
  limits; see [session migration](session-migration.md). A copied or rewritten
  database is not proof that the browser opens signed in.
- **Steam:** a library bridge can use games in place, without another download.
- **Office:** the helper copies your selected styles, dictionaries, and preferences for LibreOffice.
- **Apps:** the dashboard lists apps from Windows and suggests alternatives for Linux.
- **WSL:** selected dotfiles and package lists can help rebuild tools, not clone
  an entire WSL system or transfer its accounts. Follow the
  [WSL migration guide](wsl-migration.md) and keep a separate export/backup.
- **Wi-Fi:** the helper creates NetworkManager connections from saved networks.
  Enterprise networks can need a fresh sign-in.
- **Windows look:** the helpers transfer your selected preferences and shortcuts on supported desktops.

A category's presence does not prove every account or application will transfer.
Check your files and application state on Linux before you remove any source data.
Keep your own backup. Do not assume a repeat import will preserve your later edits.

### Existing Linux files and repeat imports

Import is not permission to replace work already made on Linux. Standard
external-file copies publish complete new files without overwriting an existing
destination; unsafe symlinks/special files refuse. Office templates, fonts,
autocorrect and defaults preserve different native content rather than counting
it as migrated. Dictionary append uses a recovery journal and refuses a changed
pending state. Read each category's result: a failed, partial or unverified
selected category makes external import return nonzero even if others completed.
The GUI must surface its actionable item error rather than “All set.”
Scheduling desktop-look changes is only partial until actually applied, not a
completed preference import.

Browser import uses safe source traversal and exclusive publication.
An existing Firefox import directory refuses a repeat copy, preserving Linux
edits. Existing Firefox `profiles.ini` is not rewritten: a copied profile may
need manual registration, and that case reports failure/advice rather than a
false complete result. Failed copies can retain private `.wootc-*.partial`
staging directories for inspection. Do not delete source data or assume a
retry will overwrite/repair the target automatically.

The Steam bridge keeps an existing library VDF byte-for-byte. If the Windows
library is not already registered, use Steam's **Add Library** UI; the bridge
does not silently rewrite native library configuration. WSL dotfiles, `.ssh`
and Brewfile imports also preserve existing different destination bytes; merge
desired configuration/formulae manually rather than assuming a retry replaces
them. Per-item `copied`, `alreadyPresent`, `preserved` and `failed` outcomes
describe what actually happened. None proves a live account is signed in.

VS Code, Telegram, Signal, Thunderbird and OBS file/profile imports likewise
preserve existing destinations rather than replacing them. New files or
complete new profile trees publish exclusively as the target user; the helper
does not recursively take ownership of unrelated native content. Thunderbird
profile metadata is created only inside its new bundle. Read per-app copied,
preserved and failed outcomes in `bridge-apps.json`; failed imports return
nonzero. Copying a messenger profile or a synthetic fixture is not a verified
login or a substitute for the app's own re-link procedure.

## 5. Try it first, commit later

The RC requires Linux-inside-Windows first, according to
[#596's Option A decision](https://github.com/tuna-os/wootc/issues/596#issuecomment-6514382140).
Current source can prepare a persistent VM disk with a selected Linux account,
then stop/start that disk through the managed QEMU/WHPX runtime. It does not
yet establish the complete consumer desktop journey: `desktopReady` remains
false without independent guest evidence.

Use only a matching signed runtime and an explicitly admitted image.
See [managed VM requirements and lifecycle](managed-vm.md) before trying it.
A helper receipt or QEMU process is not proof of graphical login, persistence,
or native promotion. Current managed-disk promotion can attempt a verified
read-only boot-input export, but still reports **not armed**; it does not
silently redeploy, discard the existing system or write BCD/ESP.
[ADR 0004](adr/0004-restore-vm-first-product.md) requires the same installed
system and data to survive eventual native boot; that positive gate remains open.

## 6. Import from another disk or a backup

On Linux, **Bring Your Windows Over** can import from another Windows drive.
The source can be a second internal disk, a USB drive, or a backup.

1. **Scan** for Windows drives.
2. **Unlock** an encrypted source with your password or 48-digit recovery key.
   This import path mounts the source read-only. It does not decrypt the drive in place.
3. **Pick the user** whose files you want.
4. **Choose the categories** to import and review their destinations.

This separate import path does not open the alpha's encrypted-PC install gate.

## 7. Encryption & BitLocker

**Not yet available in the alpha:** installation on an encrypted Windows drive.

The alpha refuses to install on a BitLocker-protected Windows drive. **Editable Documents: not proven green yet.**
Experimental code and VM results do not change that release policy.
The editable Documents candidate still needs its own complete acceptance run.
See [current status](status.md) and [issue #34](https://github.com/tuna-os/wootc/issues/34).

The experimental storage plan can put Linux on an unencrypted volume while Windows retains BitLocker.
It can use another volume or propose a new partition.
A partition change needs a separate safety review; it does not have the same scope as a disk-file install.

**Your BitLocker recovery key.** Linux uses your recovery key to open the Windows drive on each start.
It needs the key to show your Windows folders until you convert them to Linux folders.
The installer writes a copy to the installer folder, which only administrators can read.
The Linux installer moves that copy into the Linux disk and erases the copy on the Windows side.

The TPM path attempts to seal the copy to this PC. It refuses a default-PCR
binding downgrade on a TPM machine, retaining root-only plaintext for a
retry rather than pretending the weaker seal met that requirement.
Only when there is no usable TPM can the host-only fallback keep a local
sealing key beside the encrypted recovery key. That fallback does **not**
protect against an attacker who can read the whole unencrypted Linux disk.
The helpers attempt to erase the retained key when the last linked Windows
folder is converted or the Linux disk is deleted, but deletion is not proof
that all storage remnants or backups have been erased.

If the sealed copy fails, for example after a TPM clear, Linux writes a message to the system log.
Your Windows folders stay on the Windows drive.
To show them again, save your recovery key as `/etc/wootc/bitlocker-key`, readable only by root, and restart.

Linux disk encryption is a separate choice:

- **TPM auto-unlock:** a planned LUKS/TPM path; current install admission refuses
  `tpm2-luks` until its remaining safety gates are satisfied. A UI default or
  option is not evidence of working encryption.
- **Passphrase:** Linux disk encryption that requires a password at boot;
  verify that the selected image/path is qualified.
- **None:** anyone with access to the disk can read its contents.

**One-time MOK enrollment.** Some distributions sign their kernel or drivers with their own key.
Universal Blue images such as Bazzite, Bluefin and Aurora do, so Secure Boot rejects those drivers until you enroll the key.
The installer's final screen tells you if the chosen image needs enrollment.
On the blue **MOK management** screen, approve the key: **Enroll MOK** → **Continue** → **Yes**.
Use the distribution's documented enrollment password, `universalblue`, for supported images from Universal Blue.
Secure Boot stays on, but a later key change can need another enrollment.

<a id="8-go-linux-only-phase-3"></a>

## 8. Go Linux-only

Native graduation and Windows removal are different operations.
The current execution path can graduate Linux onto a separate disk that the harness verifies as blank in the test harness.
It retains Windows and the original `root.disk`.
This proof does not establish an install onto free space on the same disk.

The helper also prints plans for an in-place move and Windows removal.
The app cannot execute those plans for normal use.
Do not treat a plan, a converted-folder marker, or a snapshot check as proof that all your data has moved.
The required safety and recovery gates remain open on the [roadmap](../ROADMAP.md).

Keep both systems until you have verified your work and a separate backup.

<a id="9-uninstall--put-everything-back"></a>

## 9. Uninstall

Open **Settings → Apps → Installed apps** and find the matching product.
The older generic build registers **TunaOS (wootc)**; branded/native setup
names follow their package identity and need a real Settings-rendering check.
Open that app and choose **Uninstall** on Manage for the engine's data choices.

The uninstaller tries to:

- Remove wootc's boot entries and owned files from the boot partition.
- Remove installer files.
- Restore the recorded Fast Startup and hibernation settings.

It keeps `root.disk` by default. Default cleanup removes known installer
subtrees and only empty disk/root directories; unfamiliar saved data and VM
metadata remain even when a known root-disk filename is absent.
Select **Also delete my Linux data** only if you intend explicit recursive
product-tree deletion, including retained product data—not merely app removal.
A dedicated volume needs additional ownership and content checks before the app offers to return its space to Windows.
If ownership or contents remain uncertain, the app preserves the partition and gives a reason.

Current-source cleanup must confirm BCD rollback before removing recovery
tasks, EFI files or state. If boot cleanup, file removal, secret sanitization
or restoration of power settings fails, it reports the error and retains
recovery/retry authority where possible; it does not report complete cleanup
merely because deletion was requested. A corrupt/unreadable journal or orphaned
armed/deployer marker means **needs repair**, not “no installation.”
Removal keeps the Linux disk unless you explicitly choose otherwise.

The Add/Remove registry entry must carry the engine's ownership marker before
reuse or removal. An unmarked or foreign same-name entry is refused rather
than adopted automatically. Do not delete its marker or state to bypass refusal.

An incomplete cleanup can leave files or boot state behind.
Read any reported errors before you retry.
Uninstall does not undo work that you made on a graduated native disk.

<a id="10-troubleshooting"></a>

## 10. Problems and recovery

- **“Boot Windows once and shut down fully.”** Fast Startup or hibernation can leave the drive locked.
  Boot Windows and use a full shutdown before you retry.
- **Stuck at the boot menu:** choose **Windows Boot Manager**.
  If Windows does not start, use the recovery instructions for that failure.
- **Setup stopped and Windows started again:** open wootc.
  The recovery screen shows the boot configuration that wootc reads now.
  **Keep Windows only** removes the wootc entries from the boot order. It keeps the files, so you can try again later.
  **Repair boot** writes the installer boot files again and sets the next restart to the installer.
  wootc disables a button when it cannot prove that it owns the boot entries or files.
  From a command prompt, `wootc.exe recover --inspect` shows the same report and changes nothing.
  Each check saves its evidence in `C:\wootc\install\repair\`. Attach that folder to a bug report.
- **An import asks you to sign in:** authenticate again in the destination app.
  Browser profile transfer and account credentials have different limits.
- **No TPM:** review the passphrase and unencrypted choices under **Advanced**.
  An encryption choice does not remove the UEFI requirement.
- **Setup stopped before it finished:** open wootc again.
  It shows how the last install ended (cancelled, closed, or failed) and the last step that finished.
  **Continue setup** keeps the checked part of the download and asks for your password again.
  If setup stopped during startup-file changes, or its journal/markers are
  damaged or ambiguous, it offers repair/removal guidance rather than assuming
  there is no installation. Removal retains Linux data by default; inspect
  reported errors before attempting another install.
  To see the same result in a terminal, run `wootc.exe recover --classify`.
- **Windows asks to scan a drive:** a power cut or forced shutdown can leave it unclean.
  Complete the Windows check and inspect its result. Do not assume every file survived a failed shutdown.

For support, retain the exact release/build SHA, frontend, selected image,
`C:\wootc\state.json` (or the selected drive's install root) and relevant
`logs\` / `install\` evidence. Review it before sharing: logs and profile paths
can contain personal data. Never attach passwords, recovery keys, cookies,
session envelopes or a complete browser profile to a public issue.
Current-source engine diagnostics include JSON lines on **stderr** with
`timestamp`, `attemptId`, stable `phase`, `event`, `duration_ms` and optional
`error_code`. Events are `phase_start`, `phase_complete`, `phase_error` and
`phase_cancelled`; error codes are coarse `operation_failed` / `cancelled`,
not raw failure text. The protected journal retains diagnostic errors.
Do not mix stderr diagnostics into the stdio JSON-RPC stdout stream.

For a Windows profile mapping, review the full editable account plan before
continuing. Secondary generated names use `user1`, `user2`, and so on; a
collision with your selected primary name is not permission to drop a profile.
Duplicate, invalid or reserved Linux names are refused, and the reviewed
Windows-profile set must still match what the engine discovers. The legacy
installer refuses when it cannot establish the original interactive user or
when alternate-admin elevation changes that identity; environment hints are
not authority to collect another user's secrets.

If copying encrypted Windows Documents fails, the bridge preserves an existing
Linux Documents directory rather than hiding native files behind a read-only
Windows bind. Inspect the logged source path and use it for manual recovery;
a fallback is not proof that the copy succeeded. Keep the Windows source.

wootc remains early software. The tests cover some scenarios for native installation in VMs.
It does not establish complete VM-first use or real-hardware acceptance.
See the [status](status.md), [verification ladder](milestones.md), and [roadmap](../ROADMAP.md).
