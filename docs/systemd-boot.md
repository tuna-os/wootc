# systemd-boot packaging and trust policy

Catalog entries carry explicit `bootloader` and `composeFs` metadata. EL10
presets use GRUB2 without the composefs backend; all other presets use
systemd-boot with composefs. A custom catalog at `C:\wootc\images.json` can
override either field. The GUI accepts tagged or digest-pinned images under
`ghcr.io/tuna-os`, `ghcr.io/ublue-os`, and `ghcr.io/projectbluefin`; custom
references conservatively default to composefs plus systemd-boot.

The EFI executable is a build artifact, not a runtime download. `just
bundle-systemd-boot` extracts Fedora's binary beside the packaged application
at `app/build/bin/efi/systemd-bootx64.efi`. Unsigned builds work only when
Secure Boot is known to be off. A release may substitute
`systemd-bootx64.efi.signed`; Windows must report its Authenticode status as
`Valid` before the installer uses it while Secure Boot is enabled or unknown.
The installer never treats an unverified binary as Secure-Boot-capable.

The initial entry is `ESP:/loader/entries/wootc-deployer.conf`. Deployment
replaces it with `wootc.conf`; `wootc-esp-sync.service` then atomically
refreshes the installed kernel, initramfs, and BLS entry after OS updates.
