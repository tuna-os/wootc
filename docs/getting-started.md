# Getting started — downloading and opening wootc

This page walks you from "I found wootc" to the installer's first screen,
including Windows prompts that you **may** see on the way.
Their appearance and available choices depend on your Windows settings.

## 1. Download

Grab the latest `wootc.exe` from the
[Releases page](https://github.com/tuna-os/wootc/releases/latest). Save it
anywhere — Downloads is fine. wootc is a single program that you run.
Its current Wails interface needs the WebView2 runtime. If that runtime is missing, the app can show a prompt to install it.

Prefer a specific distribution? The same release page carries branded
builds of the identical engine — `Bazzite-Installer.exe`,
`Bluefin-Installer.exe`, `Aurora-Installer.exe`, `TunaOS-Installer.exe`.
They pre-select their own images and download the whole OS while still on
Windows, which is the right choice on a Wi-Fi-only laptop.

Command-line folks can use winget once the package clears Microsoft's
one-time review: `winget install TunaOS.wootc`.

To check your download, compare the release's `SHA256SUMS` entry with
PowerShell's `Get-FileHash .\wootc.exe` result.
A matching checksum confirms the file matches that manifest. It does not identify the publisher.
The app checks hashes and a signed manifest for its boot artifacts.

Your browser may say something like *"wootc.exe isn't commonly downloaded"*
and hide the file behind a menu. SmartScreen checks file and publisher reputation.
A warning can reflect an unknown or negative reputation.
If you trust the source and want to continue, choose **Keep** in Edge: `…` → *Keep* → *Keep anyway*.

## 2. The blue "Windows protected your PC" screen

When you open `wootc.exe`, SmartScreen can show **Windows protected your PC**.
The current release pipeline does not sign the Windows executable.
A signature identifies a publisher; it does not guarantee that SmartScreen will accept a new file.
[Microsoft describes the checks for file and publisher reputation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation).

If you trust the source and Windows offers the choice, click **More info**, then **Run anyway**.
Windows policy can prevent continuation.

If you want to verify the download first (a good habit): the Releases page
lists a SHA-256 checksum for each file. In PowerShell,
`Get-FileHash .\wootc.exe` prints yours to compare.

## 3. The administrator prompt

Next, Windows asks: *"Do you want to allow this app from an unknown
publisher to make changes to your device?"*

wootc needs administrator rights to create the Linux disk file and change the boot setup.
It also reads the system information that it shows you.
The current unsigned executable has no verified publisher identity. Choose **Yes** if you want to allow those changes.

## 4. You're in

From here, the app itself takes over — and the first screen tells you the
most important thing before asking you for anything:

> Bring Windows to Linux — keep everything.

The **Install** button starts changes before you restart.
The app creates the Linux disk file, copies boot files to the EFI system partition, and changes Windows startup settings.
The installer describes each step as it happens.

To uninstall, use **Settings → Apps → TunaOS (wootc) → Uninstall**.
Cleanup can fail and leave files or boot state behind. Linux data removal is a separate choice in Manage.
See the [user guide](user-guide.md#9-uninstall--put-everything-back) for the cleanup actions and data choices.
