# wootc handoff — Windows E2E automation pivot

Updated: 2026-07-15 UTC

## Decision

Stop treating WinRM, Podman host-port forwarding, and screen automation as the
primary Windows E2E control plane. The next implementation should use the
**QEMU Guest Agent (QGA)** over a private virtio-serial socket.

This is a small change to the existing Dockur/QEMU setup, not a migration to a
different VM product. It removes the specific failure modes that have consumed
the current iteration: guest networking, Netavark DNAT state, Windows account
credentials, WinRM authentication, the firewall, and encrypted offline disk
inspection.

## Current target

Phase 2 is the acceptance target:

1. Fresh Windows 11 install under KVM + TPM 2.0 + Secure Boot.
2. Windows creates `root.disk`, copies the deployer, installs `wubildr.efi`,
   and configures the one-shot BCD entry.
3. The deployer boots and completes Linux installation.
4. Windows returns after that one-shot deployer boot.
5. The test explicitly schedules the installed Phase 2 Linux root, observes a
   successful Linux boot, then observes a successful Windows return.

The Phase 2 target is not yet green end-to-end.

## What is proven

- Kanpur has working KVM acceleration. The E2E QEMU command contains
  `-accel=kvm -enable-kvm`, TPM emulation, and Secure Boot firmware.
- A pristine Windows 11 installer is cached on Kanpur at
  `~/wootc/tests/e2e/iso-cache/windows-11.iso`; it is intentionally kept
  separate from Dockur's mutable working ISO.
- A standard Windows 11 desktop installs successfully from that cache.
- `autounattend.xml` has the required GPT disk configuration. The historical
  installer stall at the disk picker is fixed.
- The custom `wubildr.efi` is built and copied by the current E2E payload.
- The correct BCD technique is `bcdedit /copy {bootmgr}`; the earlier
  `/create /application firmware` approach is invalid on Windows 11.
- The OEM task is created during `specialize` and runs at first logon as
  `SYSTEM`, avoiding UAC/user-context problems.

## Important current findings

### WinRM is the wrong dependency

1. In rootful Podman, Netavark retained a host-port DNAT target for an older
   compose network (`10.89.0.2`) while the active Dockur container was
   `10.89.5.2`. This made `host:5985` misleading or unreachable.
2. From the active container network namespace, the actual Windows TAP guest
   (`172.30.5.2` in that run) accepted TCP on 5985. Therefore the VM and
   Windows service were alive; host port forwarding was the faulty layer.
3. The direct WinRM probe still received credential rejection for all tested
   historical account/password combinations. It is not a reliable test API.
4. `tests/e2e/fix-winrm.py` can open elevated PowerShell, but currently leaves
   Windows Start search focused. Its typed commands go into search instead of
   PowerShell. It must not be used as the normal test path.

Commit `717e7de` is already pushed. It makes the runner prefer entering the
Dockur container's network namespace (`nsenter -t <container-pid> -n`) and
connect directly to the TAP guest, retaining the old port route as a fallback.
It also enables Basic WinRM in the OEM script and emits compact OEM status
markers to COM1. This is a useful safety improvement, but QGA should replace
the control dependency rather than extending it further.

### Offline QCOW inspection cannot recover OEM logs

The Secure Boot + TPM configuration enables Windows Device Encryption. A live,
read-only point-in-time QCOW copy correctly showed the C: partition as an FVE
(BitLocker) volume, not mountable NTFS. This rules out offline `C:\OEM` log
inspection as a dependable debugging strategy.

A temporary partial diagnostic image may exist on Kanpur as
`tests/e2e/storage/e2e-inspect.qcow2`; it is disposable and should be removed
before the next large run.

## Recommended QGA design

### Host/QEMU wiring

Dockur's `/run/config.sh` appends the `ARGUMENTS` environment variable directly
to QEMU. Add this value to the E2E Compose service:

```text
-chardev socket,id=qga0,path=/run/shm/qga.sock,server=on,wait=off
-device virtio-serial
-device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
```

The runner can access `/run/shm/qga.sock` with `podman exec`; it is private to
the VM container and needs neither a network port nor guest credentials.

### Bootstrap once, then control everything through QGA

1. Cache the small signed `qemu-ga-x86_64.msi` in an ignored E2E cache and copy
   it into `C:\OEM` with the existing payload.
2. Keep one minimal, first-logon `SYSTEM` scheduled task. Its only job is a
   silent agent install, e.g. `msiexec /i C:\OEM\qemu-ga-x86_64.msi /qn
   /norestart`, and starting the QEMU Guest Agent service.
3. The host runner waits for `guest-ping` on `qga.sock`.
4. Use QGA `guest-exec` to run the existing PowerShell payload as `SYSTEM`,
   capture stdout/stderr, and use `guest-file-open/read` for `C:\OEM` logs.
5. Use QGA `guest-exec` for BCD queries, scheduling the Phase 2 one-shot boot,
   and reboot requests. After every Windows return, `guest-ping` becomes the
   definitive readiness assertion.

The QGA service runs with local system privileges, so BCD/ESP actions no longer
depend on a UAC session or a remote Windows user.

### Suggested runner interface

Add a small standard-library Python client (for example `tests/e2e/qga.py`)
that talks JSON lines to `/run/shm/qga.sock` and supports:

- `guest-ping` / `guest-info` for readiness and diagnostics;
- `guest-exec` + `guest-exec-status` with captured stdout and stderr;
- `guest-file-open/read/close` for OEM logs and BCD GUID files;
- `guest-shutdown` only where a Windows-native reboot is preferred.

Do **not** use the QEMU HMP keyboard monitor for normal execution. Retain it
only for screenshots/emergency debugging.

## Agent package source

The official virtio-win download endpoint was reachable from Kanpur on
2026-07-15:

```text
https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-qemu-ga/qemu-ga-x86_64.msi
```

At that time it redirected to `qemu-ga-win-110.0.2-1.el10` and reported a size
of 11,793,408 bytes. Download it once, record its SHA-256 alongside it, and use
the cached copy for every run; do not download it from inside the Windows VM.

Use the focused QGA MSI rather than the complete `virtio-win-guest-tools.exe`:
it is smaller and avoids unrelated driver/installer components.

## Alternatives considered

| Tool | Fit | Decision |
| --- | --- | --- |
| QEMU Guest Agent + QMP-style agent socket | Direct command/file API over a private virtio device; no network or Windows credentials. | **Use this.** |
| Packer QEMU builder | Useful for building a reusable golden Windows image, but its standard communicators are SSH/WinRM/none. It does not solve the running-VM control problem. | Optional later for image caching only. |
| Windows OpenSSH | Microsoft-supported, but must be installed/enabled, needs a firewall/port route and credentials/keys. | Better than WinRM for humans, not the E2E control plane. |
| Ansible/WinRM | Adds orchestration around the same fragile dependency. | Do not add. |
| VNC/noVNC/keyboard automation or openQA | Appropriate only for visual installer assertions; timing/focus-dependent for provisioning and log retrieval. | Keep screenshots only as fallback diagnostics. |
| libvirt/virsh | `virsh qemu-agent-command` is pleasant, but changing Dockur to libvirt adds a VM-stack migration without improving the underlying protocol. | Do not migrate now. |

## External references

- [QEMU Guest Agent overview](https://www.qemu.org/docs/master/interop/qemu-ga.html)
  documents the host-to-guest management service and its virtio-serial default.
- [QEMU Guest Agent protocol reference](https://www.qemu.org/docs/master/interop/qemu-ga-ref.html)
  documents `guest-exec`, captured output, `guest-file-*`, `guest-ping`, and
  Windows-supported operations.
- [Dockur Windows](https://github.com/dockur/windows) remains the current VM
  wrapper; local inspection of the running image confirmed its `ARGUMENTS`
  support.
- [Packer communicators](https://developer.hashicorp.com/packer/docs/communicators)
  lists SSH, WinRM, and none, which is why Packer is not the control-plane fix.
- [Microsoft OpenSSH Server setup](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse)
  confirms the additional installation, service, firewall, and account setup
  that make it a secondary option.

## Next concrete steps

1. Remove the temporary `e2e-inspect.qcow2` diagnostic image on Kanpur.
2. Download/cache the QGA MSI on Kanpur, verify and record its SHA-256.
3. Add QGA QEMU arguments to `tests/e2e/compose.yml`.
4. Stage the MSI in the OEM payload and reduce the first-logon scheduled task
   to the silent QGA bootstrap only.
5. Implement and test a `qga.py` client against a fresh Windows E2E VM.
6. Move OEM setup, log retrieval, reboot control, and Phase 2 BCD scheduling
   from WinRM to QGA.
7. Preserve serial screenshots as failure evidence, but make QGA output the
   primary E2E diagnostic.

Commit and push each independently verified improvement, as requested.
