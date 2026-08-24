<h1 align="center">wootc</h1>

<p align="center"><strong>Try Linux from inside Windows — no repartitioning, nothing deleted, fully reversible.</strong></p>

<p align="center">
  <a href="https://github.com/tuna-os/wootc/releases/latest"><img src="https://img.shields.io/github/v/release/tuna-os/wootc?label=release&color=2eb9df" alt="Latest release"></a>
  <a href="https://github.com/tuna-os/wootc/actions/workflows/e2e-gui.yml"><img src="https://github.com/tuna-os/wootc/actions/workflows/e2e-gui.yml/badge.svg" alt="Nightly E2E"></a>
  <a href="https://github.com/tuna-os/wootc/actions/workflows/ci.yml"><img src="https://github.com/tuna-os/wootc/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-GPL--2.0%20%2B%20MIT-blue" alt="License"></a>
</p>

<p align="center">
  <a href="https://tuna-os.github.io/wootc/e2e/latest/">
    <img src="https://tuna-os.github.io/wootc/e2e/latest/preview.webp"
         alt="wootc end-to-end walkthrough — Windows 11 → wootc deployer → native Linux → Windows 11"
         width="760">
  </a>
  <br>
  <em>▶ The latest <strong>green</strong> end-to-end run, sped up: Windows 11 → wootc → native Linux booting from a file → back to Windows. <a href="https://tuna-os.github.io/wootc/e2e/latest/">Play the full timelapse.</a> Only passing runs are ever published here.</em>
</p>

---

wootc installs a real, image-based [bootc](https://github.com/containers/bootc)
Linux desktop into `root.disk` — a single file beside your Windows files — and
adds a boot menu entry for it. **No repartitioning. No backup ceremony. No
point of no return.** Windows stays your default boot until you decide
otherwise, and uninstalling is deleting a folder and a boot entry.

Setup asks for as much as a Mac's first-run assistant would: **a password.**
Your username and computer name are mirrored from your PC, the disk is sized
from your free space, encryption is TPM-backed by default — and your files,
Wi-Fi networks, wallpaper, and taskbar carry over, so the first login already
feels like your machine.

## Get it

**[⬇ Download the latest release](https://github.com/tuna-os/wootc/releases/latest)**
— one exe, no setup wizard. Run it as Administrator; it fetches and verifies
its own boot pieces against the release's `SHA256SUMS`.

```
winget install TunaOS.wootc
```
*(winget availability lands with the first accepted submission.)*

Every release also ships **branded installers** — `Bazzite-Installer.exe`,
`Bluefin-Installer.exe`, `Aurora-Installer.exe`, `TunaOS-Installer.exe` — the
same engine wearing each distribution's identity, pre-selected to its images
and pre-downloading the OS while still on Windows (no network needed after
the reboot).

> The binaries are not yet code-signed, so Windows shows SmartScreen and an
> "unknown publisher" prompt on the way in.
> **[Getting started](docs/getting-started.md)** walks through both screens;
> the **[user guide](docs/user-guide.md)** covers everything after, including
> [putting everything back](docs/user-guide.md#9-uninstall--put-everything-back).
> Trying it on your own hardware? Read
> **[manual testing](docs/manual-testing.md)** first.

## How it works

```
Windows 11  →  wootc.exe (arms the system)  →  reboot
            →  signed shim → GRUB → deployer initramfs
            →  fisherman: bootc install into root.disk
            →  reboot → native Linux, loop-mounted from root.disk
            →  (optional, later) graduate to a real partition
```

1. **Arm.** The app creates `C:\wootc\disks\root.disk`, stages a
   Microsoft/Fedora-signed boot chain on the ESP, and sets a **one-shot**
   boot entry. Nothing else on the machine is touched.
2. **Deploy.** One reboot: under Secure Boot, the signed chain launches a
   small installer environment that writes the chosen OS image into
   `root.disk` — with optional LUKS/TPM2 encryption.
3. **Live in both.** A boot hook attaches `root.disk` on every boot and
   pivots into an unmodified, native Linux system. Windows stays on the boot
   menu, and your Windows drive is right there in the file manager.
4. **Commit — or don't.** Graduate Linux onto a real partition when you're
   sure, keep dual-booting forever, or uninstall and leave no trace.

## What you get

- **A password is the whole form.** Solid defaults for everything else,
  stated on screen and adjustable under Advanced.
- **Your stuff comes along** — files, Wi-Fi networks, wallpaper, accent
  color, keyboard layout, taskbar pins, browser profiles (Firefox, Chrome,
  Edge), Steam libraries, MS Office → LibreOffice settings, WSL dotfiles and
  packages. Secrets never move silently: passwords, keys, and tokens stay
  put, and you sign in again where it matters.
- **BitLocker-safe.** C: is never decrypted — Linux gets its own unencrypted
  space while your Windows drive stays protected.
- **A real image catalog** — GNOME, KDE Plasma, Niri, and XFCE desktops on
  Enterprise Linux, Fedora, Arch, and Debian bases, or any supported custom
  OCI image.
- **Try before you reboot** — boot the result in a VM window from inside
  Windows first.
- **An honest way back.** Uninstall lives in Windows' own Apps list, removes
  the boot entry and installer, restores changed settings, and only ever
  reclaims a partition wootc itself created.

## Trust, engineered

Every release is **gated on a full end-to-end run**: a real Windows 11 VM
(Secure Boot + TPM 2.0) installs that exact build through the real GUI, boots
natively into Linux from `root.disk`, and returns to Windows cleanly — no
green run, no release. Nightly green runs cut automatic pre-releases from the
exact commit they proved, and every failed check in the harness is
release-blocking by construction.

The current proven matrix — image families, Windows editions, filesystems,
encryption modes — lives in **[docs/status.md](docs/status.md)**. The project
is in **alpha** on the road to a checkable 1.0: see the
**[ROADMAP](ROADMAP.md)** for the version ladder and its evidence gates, and
**[docs/philosophy.md](docs/philosophy.md)** for the thinking behind it all.

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
| [Branding & distribution](docs/branding-and-distribution.md) | one engine, five installers |
| [Manual testing](docs/manual-testing.md) | pre-flight for real-hardware runs |

## Contributing

The stack: a [Wails](https://wails.io) (Go + web) Windows app, a dracut-based
deployer initramfs, POSIX-shell migration tooling, and a KVM E2E harness that
drives real Windows VMs through the real GUI.

```bash
just test                              # fast tier: bats + go, no containers
just build                             # deployer initramfs + custom GRUB
cd tests/gui && npx playwright test    # GUI suite over the built frontend
```

See **[CONTRIBUTING.md](CONTRIBUTING.md)** — the best first contributions
turn a claim green: a red or unproven matrix cell, or an open milestone task
on the [tracking boards](https://github.com/tuna-os/wootc/issues/210).

## License

Windows installer components derived from
[WubiUEFI](https://github.com/hakuna-m/wubiuefi) are **GPL-2.0**
([LICENSE-GPL-2.0](LICENSE-GPL-2.0)); the deployer initramfs and GRUB
configuration are **MIT** ([LICENSE-MIT](LICENSE-MIT)). fisherman, bootc,
bootupd, podman, and skopeo are separate binaries under their own
(Apache-2.0) licenses, invoked over a process boundary.
