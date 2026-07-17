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
Secure Boot is known to be off.

Debian Trixie Secure Boot release packaging may additionally provide:

```
efi/debian/shimx64.efi
efi/debian/systemd-bootx64.efi.signed
```

The pair must come from Debian's `shim-signed` and
`systemd-boot-efi-amd64-signed` packages. Windows must validate both
Authenticode signatures. The installer copies the signed loader to shim's
expected `EFI/systemd/grubx64.efi` next-stage name and points BCD at shim. A
lone signed loader is never considered a trusted chain. Missing assets or an
invalid signature fail closed whenever Secure Boot is enabled or unknown.

The initial entry is `ESP:/loader/entries/wootc-deployer.conf`. Deployment
replaces it with `wootc.conf`; `wootc-esp-sync.service` then atomically
refreshes the installed kernel, initramfs, and BLS entry after OS updates.
