# systemd-boot packaging and trust policy

Catalog entries carry explicit `bootloader` and `composeFs` metadata. EL10
presets use GRUB2 without the composefs backend; all other presets use
systemd-boot with composefs. A custom catalog at `C:\wootc\images.json` can
override either field. The GUI accepts tagged or digest-pinned images under
`ghcr.io/tuna-os`, `ghcr.io/ublue-os`, and `ghcr.io/projectbluefin`; for a
custom reference, the default is the conservative choice: composefs plus
systemd-boot.

The EFI executable is a build artifact, not a runtime download. `just
bundle-systemd-boot` extracts Fedora's binary beside the packaged application
at `app/build/bin/efi/systemd-bootx64.efi`. Unsigned builds work only when
Secure Boot is known to be off.

For Secure Boot, a release package for Debian Trixie can also supply:

```
efi/debian/shimx64.efi
efi/debian/systemd-bootx64.efi.signed
```

The pair must come from Debian's `shim-signed` and
`systemd-boot-efi-amd64-signed` packages. Windows must validate both
Authenticode signatures. The installer copies the signed loader to shim's
expected `EFI/systemd/grubx64.efi` next-stage name and points BCD at shim. A
lone signed loader is never considered a trusted chain. When Secure Boot is on
or its state is unknown, the installer fails closed if an asset is missing or
a signature is not valid.

The initial entry is `ESP:/loader/entries/wootc-deployer.conf`. Deployment
replaces it with `wootc.conf`; `wootc-esp-sync.service` then atomically
refreshes the installed kernel, initramfs, and BLS entry after OS updates.

## composefs images on the GRUB chain

The installer stages the signed Fedora shim and GRUB by default.
Thus GRUB starts Phase 2 of a composefs image, not systemd-boot.
bootc reads the `LoaderInfo` EFI variable to find its boot entries.
GRUB sets that variable to GRUB, so bootc looks in `/sysroot/boot`.
`bootc install --bootloader systemd` writes the entries on the ESP of `root.disk`.
Then `bootc status` fails on the installed system.

So the deployer reads `LoaderInfo` when the deployer starts.
If the loader is not systemd-boot, `wootc-cfs-boot adopt` moves the entries and their kernel folders into `/sysroot/boot`.
That is the layout that `bootc install --bootloader grub` makes.
Then `wootc-cfs-boot sync` writes a menu on the Windows ESP, with one item for each bootc entry.
The items have the order that bootc uses for GRUB: the file names in reverse order.

`wootc-esp-sync.service` runs the sync at boot.
`wootc-esp-sync-shutdown.service` runs it at shutdown, after `bootc-finalize-staged.service`.
Thus an upgrade or a rollback starts on the next boot.

Each menu entry starts the deployer kernel, because the Fedora shim trusts only that kernel.
GRUB loads `EFI/wootc/phase2-overlay.cpio` first and then the initrd of the entry.
