<h1 align="center">wootc</h1>

<p align="center"><strong>Goal: try Linux inside Windows, keep your work, and choose native boot later.</strong></p>

<p align="center">
  <a href="https://github.com/tuna-os/wootc/releases/latest"><img src="https://img.shields.io/github/v/release/tuna-os/wootc?label=release&color=2eb9df" alt="Latest release"></a>
  <a href="https://github.com/tuna-os/wootc/actions/workflows/e2e-gui.yml"><img src="https://github.com/tuna-os/wootc/actions/workflows/e2e-gui.yml/badge.svg" alt="Nightly E2E"></a>
  <a href="https://github.com/tuna-os/wootc/actions/workflows/ci.yml"><img src="https://github.com/tuna-os/wootc/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-GPL--2.0%20%2B%20MIT-blue" alt="License"></a>
</p>

<p align="center">
  <a href="https://tuna-os.github.io/wootc/e2e/latest/">
    <img src="https://tuna-os.github.io/wootc/e2e/latest/preview.webp"
         alt="wootc walkthrough — Windows 11 → deployer → native Linux → native graduation"
         width="760">
  </a>
  <br>
  <em>▶ A published native cycle with a <strong>green</strong> result, sped up. It shows the stages selected by that run; a Windows return is a separate check. <a href="https://tuna-os.github.io/wootc/e2e/latest/">Play the full timelapse.</a> The publish gate needs a green run.</em>
</p>

---

wootc installs a real Linux desktop from a [bootc](https://github.com/containers/bootc)
image into `root.disk`, a file beside your Windows files. The native path adds a boot entry.
Current releases do not yet provide the complete Linux-inside-Windows journey.
The [verification status](docs/status.md) describes the evidence and limits.
The [roadmap](ROADMAP.md) keeps VM-first use and complete restoration as release requirements.

The setup form asks for **a password**. The app suggests your username and
computer name from your PC. It sizes the disk from available space and selects TPM encryption by default.
Advanced lets you change those choices. Supported migration helpers can carry files,
Wi-Fi networks, wallpaper, and taskbar choices. Results depend on the image and helper.

## Get it

**[⬇ Download the latest release](https://github.com/tuna-os/wootc/releases/latest)**
— run the exe as Administrator. It fetches boot artifacts, checks hashes, and verifies a signed manifest.
The current Wails interface needs the WebView2 runtime. Windows may prompt you to install it.

```
winget install TunaOS.wootc
```
*(winget availability lands with the first accepted submission.)*

Every release also ships **branded installers** — `Bazzite-Installer.exe`,
`Bluefin-Installer.exe`, `Aurora-Installer.exe`, `TunaOS-Installer.exe` — the
same engine with each distribution's identity and preselected images.
They can pre-download the OS on Windows for deployment without a network after reboot.

> The binaries are not yet code-signed. Windows may show SmartScreen or an
> "unknown publisher" prompt. Policy can prevent continuation.
> **[First steps](docs/getting-started.md)** explains those prompts;
> the **[user guide](docs/user-guide.md)** describes later steps and
> [uninstall limits](docs/user-guide.md#9-uninstall--put-everything-back).
> For a hardware trial, read the **[manual test guide](docs/manual-testing.md)** first.

## How it works

```
Windows 11  →  wootc.exe (arms the system)  →  reboot
            →  signed shim → GRUB → deployer initramfs
            →  fisherman: bootc install into root.disk
            →  reboot → Windows → Manage: choose Linux boot
            →  native Linux, loop-mounted from root.disk
            →  (optional, later) graduate to a real partition
```

1. **Arm.** The app creates `root.disk` on the selected drive and stages a signed boot chain on the ESP.
   It changes Windows startup settings and sets a **one-shot** boot entry before you restart.
2. **Deploy.** Under Secure Boot, the signed chain launches the installer environment.
   It writes the chosen OS image into `root.disk`, with optional LUKS/TPM2 encryption.
   Windows normally returns after deployment. Manage offers an explicit Linux boot choice.
3. **Live in both.** A boot hook attaches `root.disk` and boots the native Linux system.
   Windows stays on the boot menu. Supported bridges expose your selected files from Windows in Linux.
4. **Choose what comes next.** Graduate Linux to a blank disk after explicit checks, or keep both systems.
   Uninstall tries cleanup; it can leave files or boot state behind.
   Linux data removal is a separate choice in Manage.

## What you get

- **A password is the whole form.** Solid defaults for everything else,
  stated on screen and adjustable under Advanced.
- **Migration helpers** cover files, Wi-Fi networks, wallpaper, accent color, keyboard layout, and taskbar pins.
  They also cover browser profiles (Firefox, Chrome, Edge), Steam libraries, MS Office → LibreOffice choices, and WSL dotfiles/packages.
  A complete Firefox profile can include saved passwords. Other app sessions may need you to sign in again.
  See the user guide for each helper's limits.
- **BitLocker-safe by design.** C: is never decrypted — Linux gets its own
  unencrypted space while your Windows drive stays protected. *Gated off in
  the alpha until the FDE path is matrix-green
  ([#34](https://github.com/tuna-os/wootc/issues/34)). The app stops and explains this gate on an encrypted drive.*
- **Image catalog** — GNOME, KDE Plasma, Niri, and XFCE desktops on Enterprise Linux, Fedora, Arch, and Debian bases.
  Custom OCI images need the channel and compatibility gates.
- **VM-first goal** — Linux must run inside Windows before native boot.
  The complete Windows-hosted desktop and persistent user-work journey remain unproved.
- **An honest way back.** Windows Apps offers uninstall. Cleanup can fail and report incomplete restoration.
  Partition removal needs current ownership and disk checks. Linux data removal is a separate choice.

## Trust, engineered

Automatic tagged releases need a **full end-to-end run** on the selected build.
The current tagged workflow uses the real GUI in Windows 11 with Secure Boot and TPM 2.0.
It selects native deployment, Linux boot, and graduation. That path ends in graduated Linux;
it does not prove a Windows return after graduation.

The manual emergency waiver remains in
[release instructions](docs/RELEASING.md).
Nightly green runs can cut automatic pre-releases from their tested commit.
Required checks must pass before a normal release.

The matrix in **[docs/status.md](docs/status.md)** records image families, Windows editions, filesystems, and encryption modes.
Historical beta releases do not prove the current VM-first or native-shell journey.
See the **[ROADMAP](ROADMAP.md)** for the version ladder and evidence gates.
**[docs/philosophy.md](docs/philosophy.md)** explains the product goals.

## Documentation

| | |
|---|---|
| [Getting started](docs/getting-started.md) | download → first boot, screen by screen |
| [User guide](docs/user-guide.md) | living in the migrated system, and the way back |
| [Philosophy](docs/philosophy.md) | the North Star, the Wubi heritage, why a file |
| [Status](docs/status.md) | the proven matrix and its evidence |
| [SPEC](docs/SPEC.md) | the full specification |
| [Architecture boundary](docs/architecture-boundary.md) | the generic-migration / bootc seam |
| [NTFS on Linux](docs/ntfs-on-linux.md) | the known hazards, and why the design survives them |
| [Borrowed from Libertix](docs/borrowed-from-libertix.md) | six boot-chain and recovery designs, specified against wootc's code, with task lists |
| [WinUI 3 shell](docs/winui-shell.md) | the native Windows shell that replaces Wails: architecture, engine protocol, cut-over |
| [Branding & distribution](docs/branding-and-distribution.md) | one engine, five installers |
| [Manual testing](docs/manual-testing.md) | pre-flight for real-hardware runs |

## Contributing

The current Windows app uses [Wails](https://wails.io) (Go + web).
The stack also has a dracut deployer initramfs, POSIX-shell migration tools, and a KVM E2E harness.
That harness drives the real GUI in Windows VMs.

```bash
just test                              # fast tier: bats + go, no containers
just build                             # deployer initramfs + custom GRUB
cd tests/gui && npx playwright test    # GUI suite over the built frontend
```

See **[the contribution guide](CONTRIBUTING.md)**.
Start with a red or unproven matrix cell or an incomplete milestone task
on the [task boards](https://github.com/tuna-os/wootc/issues/210).

## License

Installer components for Windows derive from
[WubiUEFI](https://github.com/hakuna-m/wubiuefi) and use **GPL-2.0**
([LICENSE-GPL-2.0](LICENSE-GPL-2.0)); the deployer initramfs and GRUB
configuration are **MIT** ([LICENSE-MIT](LICENSE-MIT)). fisherman, bootc,
bootupd, podman, and skopeo are separate binaries under their own
(Apache-2.0) licenses, invoked over a process boundary.
