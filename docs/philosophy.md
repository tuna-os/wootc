# Philosophy — why wootc exists and how it decides

## The North Star

> Make it as easy as possible for **non-technical Windows users** to migrate
> to Linux **without losing any of their data**. Every decision is weighed
> against one question: *would a nervous Windows user get through this
> without fear or data loss?*

Three consequences follow, and they outrank everything else:

- **Reversibility and data safety beat feature count.** A feature that adds
  risk to the user's existing machine does not ship, however impressive.
- **Friendly language beats technical precision.** The UI says "your Windows
  files come along", not "NTFS is loop-mounted read-write via the kernel
  driver". The precise version lives in the docs, where it belongs.
- **Nothing permanent changes until Linux is proven working.** The first
  boot into the installer is a one-shot entry; the default boot order stays
  Windows until the installed system has actually come up.

## Ask nothing macOS wouldn't ask

The setup bar is a Mac's first-run assistant: the default install form asks
for **a password, nothing else**. Everything else is a solid default the
user can trust — identity mirrored from the PC they're sitting at, disk
sized from their free space, TPM-backed encryption, their files, Wi-Fi and
look brought along — each stated plainly on the form and adjustable under
Advanced. A control earns a place on the main form only when it is a
question wootc genuinely cannot answer for the user (where Linux should
live on a BitLocker machine, an identity that could not be derived).

The same principle governs migration: **everything safe to migrate,
migrates by default** — files, Wi-Fi networks, wallpaper, keyboard layout,
taskbar pins, browser profiles, Steam libraries. wootc asks only for what
it needs to do that job. What never moves silently is spelled out in the
consent tiers of [SPEC §4.6](SPEC.md#46-device-and-connectivity-migration):
passwords, private keys, tokens, and credential stores stay put — you sign
in again where it matters.

## Why a file, not a partition

Switching OS is scary because it traditionally means repartitioning,
backups, and a point of no return. wootc removes all three: Linux lives in
`root.disk`, a single sparse file beside your Windows files, both systems
boot from the same disk, and you decide if and when to make it permanent.
Uninstalling is deleting a folder and a boot entry.

This is the classic [Wubi](https://en.wikipedia.org/wiki/Wubi_(software))
idea, rebuilt for the modern stack: UEFI + Secure Boot (a Microsoft/Fedora
signed shim → GRUB chain instead of unsigned bootloaders), and
container-native [bootc](https://github.com/containers/bootc) images
(the OS is an OCI image; the same image boots from a file on NTFS or a
native partition, so "graduating" to a real disk later is a deployment,
not a reinstall).

Within the tuna-os / Universal Blue family, wootc is the **conversion
front door**: the Windows-hosted complement to the bootc-installer family,
driving [fisherman](https://github.com/projectbluefin/fisherman) under the
hood. One engine ships as five installers — generic wootc plus branded
TunaOS, Bluefin, Aurora, and Bazzite builds
([branding-and-distribution.md](branding-and-distribution.md)).

## Evidence, not claims

Nobody should trust "it works on my machine" from a tool that writes to a
stranger's only computer. So the project holds itself to evidence:

- **Releases are E2E-gated.** A release is published only after a real
  Windows VM installs that exact build through the real GUI, boots natively
  into Linux from `root.disk`, and returns to Windows cleanly. No green
  run, no release.
- **Failures are load-bearing.** The E2E harness records every failed check
  to a ledger and gates the pass banner on it — a lesson learned the hard
  way when an early harness recorded a PASS with a North-Star failure in
  its own log ([status.md](status.md) tells that story).
- **The support policy is honest.** The GUI's claims (`GetSupportPolicy`)
  flip only for scenarios the matrix has proven; anything else is refused
  with plain words rather than allowed to fail mysteriously.

What "1.0" means under this philosophy — the North Star made checkable —
is defined in the [ROADMAP](../ROADMAP.md).

## The uninstall promise

Leaving must be as safe as arriving: uninstall removes the boot entry,
bootloader files and the installer, keeps `root.disk` unless you ask it
deleted, can reclaim a dedicated Linux partition (only one wootc created —
verified by volume label), and restores the power settings setup changed.
It is listed in Windows' own Apps list, because that is where a Windows
user would look.
