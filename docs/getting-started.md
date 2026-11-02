# Getting started — downloading and opening wootc

This page walks you from "I found wootc" to the installer's first screen,
including Windows prompts that you **may** see on the way.
Their appearance and available choices depend on your Windows settings.

## 1. Download

Open the [Releases page](https://github.com/tuna-os/wootc/releases/latest) and
check the **tag and asset names actually listed**. As inspected on 2026-11-02,
the latest non-prerelease is `v0.1.0-alpha.1`. It provides `wootc.exe` and
`Bazzite-Installer.exe`, `Bluefin-Installer.exe`, `Aurora-Installer.exe` and
`TunaOS-Installer.exe`. These are older Wails builds and need WebView2.
They are not the native setup packages described by current main.

Main's release workflow now prepares native
`wootc-Installer-Setup.exe`, `Bazzite-Installer-Setup.exe`,
`Bluefin-Installer-Setup.exe`, `Aurora-Installer-Setup.exe` and
`TunaOS-Installer-Setup.exe`, with `native-SHA256SUMS` and a one-release
`wootc-legacy.exe` compatibility artifact. **Do not assume those files are
available in an older tag.** A matching native package installs the WinUI shell
and protected engine; that shell does not need WebView2. See the
[native shell status](winui-shell.md) and [verification matrix](status.md)
before testing a preview or source build.

Save the chosen executable anywhere — Downloads is fine. Verify it before
running it, then use only the instructions for that tag and frontend.
Distribution-specific builds select their own image; offline/preloaded
behavior must be checked for the particular package rather than assumed from
the brand name. The planned winget command is `winget install TunaOS.wootc`;
it is not an installation route until Microsoft's package review is complete.

To check an older published download, compare its `SHA256SUMS` entry with
PowerShell's output:

```powershell
Get-FileHash .\wootc.exe -Algorithm SHA256
```

For a native setup, use that package's actual filename and its release's
`native-SHA256SUMS`. A checksum match does not identify the publisher.
Current engine source also authenticates a signed manifest for boot artifacts;
that is separate from a Windows executable's publisher signature.

Your browser may say something like *"wootc.exe isn't commonly
downloaded"* and hide the file behind a menu. SmartScreen checks file and
publisher reputation. A warning can reflect an unknown or negative reputation.
If you trust the source and want to continue, choose **Keep** in Edge: `…` →
*Keep* → *Keep anyway*.

## 2. The blue "Windows protected your PC" screen

When you run the selected executable, SmartScreen can show **Windows protected
your PC**. Check the actual artifact's signature; main's packaging definition
does not establish that a published Windows binary is signed.
A signature identifies a publisher; it does not guarantee that SmartScreen will accept a new file.
[Microsoft describes the checks for file and publisher reputation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation).

If you trust the source and Windows offers the choice, click **More info**, then **Run anyway**.
Windows policy can prevent continuation.

If you want to verify the download first (a good habit): the Releases page
lists a SHA-256 checksum for each file. In PowerShell,
`Get-FileHash .\wootc.exe -Algorithm SHA256` prints the older generic download's
hash; substitute your actual filename.

## 3. The administrator prompt

Windows can ask: *"Do you want to allow this app to make changes to your device?"*
The publisher text depends on the artifact's signature.

wootc needs administrator rights to create the Linux disk file and change the boot setup.
It also reads the system information that it shows you.
An unsigned executable has no verified publisher identity. Choose **Yes** only
if you trust this exact download and intend to allow those changes. The native
shell normally remains unelevated and requests elevation for its protected
engine; the older Wails app uses a different launch path.

## 4. You're in

From here, the matching installer takes over. Current source uses the tagline:

> Bring Windows to Linux — keep everything.

This is a product goal, not a guarantee that every app, login or recovery path
is qualified. Older published builds and branded packages can show different
screens. The [user guide](user-guide.md) describes current-source behavior
and its evidence boundaries.

The **Install** button starts changes before you restart.
The app creates the Linux disk file, copies boot files to the EFI system partition, and changes Windows startup settings.
The installer describes each step as it happens.

To uninstall, find the matching product under **Settings → Apps**. The older
generic build registers **TunaOS (wootc)**; native setup uses its brand/package
identity, so the entry can differ. Cleanup can fail and leave files or boot
state behind. Linux data removal is a separate choice in Manage.
See the [user guide](user-guide.md#9-uninstall--put-everything-back) for the
cleanup actions and data choices.

## Coming from WSL?

Read [Moving from WSL](wsl-migration.md) before changing your setup. Keep a
separate export/backup of each WSL distribution and verify any manual file
transfer on Linux. wootc does not automatically import a WSL distribution,
accounts, passwords or running services, and it does not promise zero data loss.

Evaluating a machine for work? The [IT-admin quick start](it-admin-quick-start.md)
describes the single-machine evaluation boundary; it is not a fleet rollout guide.
