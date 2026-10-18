# Signed ESP upgrade probe

Issue [#333](https://github.com/tuna-os/wootc/issues/333) remains subject to
an actual Secure Boot upgrade and return to Windows.
The [results](evidence/2026-09-27-esp-chain/native-result.json) show verification
of the PE digest and signature. They also show an upgrade of three signed
files and restoration after termination at each publication. The production controller also authenticates a signed kernel
and publishes an owned configuration file.
Firmware variables and current boot observations in this probe are fixtures.
They do not prove a firmware boot or recovery after a hardware power cut.

The [provenance](evidence/2026-09-27-esp-chain/provenance.json) binds the public
image, RPMs, source revisions, and file hashes. Both bundles use public packages from AlmaLinux. They represent a fixture
for an upgrade, not an observed deployment from bootupd. The verifier uses code from upstream without changes to verification. Its ELF loader and libraries travel with it.

Run the preserved probe with:

```sh
python3 tests/probe-esp-chain-real.py /dev/shm/wootc-333-audit
```

For another machine, provide the same named public assets and build the
verifier closure with `packaging/build-sbverify.sh` in the pinned builder.
The probe checks the trio and kernel hashes before it creates temporary
files. It does not write to a host ESP.

Refresh stops if trust is unknown, content is foreign, or root ancestry is native.
It also stops if both shims cannot authenticate both sets of companions. Initialization needs the current EFI boot, loop root,
source image, actual ownership manifest, and complete authenticated chain.
Initialization does not accept a healthy marker or a record from firstboot.

Initial cross-vendor publication and changes to the native ESP remain under
[#286](https://github.com/tuna-os/wootc/issues/286). Kernel and initramfs
publication uses separate file transactions. It does not provide an atomic
boot-artifact pair. Systemd and native boot refreshes are outside this
shim/GRUB controller's supported scope and refuse before publication.

Classic sources under `/boot/efi/EFI/<vendor>` remain an open part of
[#333](https://github.com/tuna-os/wootc/issues/333). This controller needs
an observed deployment from bootc and a complete source from bootupd.
It refuses classic sources before any ESP write. A separate design must
bind their root identity, source provenance, and full signed chain.
