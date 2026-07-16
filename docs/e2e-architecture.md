# wootc E2E Architecture — Phase 2 Boot Chain

How the E2E test drives a real Windows 11 VM (TPM + Secure Boot) through the
full wootc flow: OEM install → deployer boot → fisherman deployment →
return to Windows. Everything here was validated live on the Kanpur KVM
host, 2026-07-15/16.

## The big picture

```mermaid
flowchart LR
    subgraph host["Kanpur (KVM host)"]
        runner["run-e2e.sh<br/>(orchestrator)"]
        share["Samba share<br/>tests/e2e/wootc-files/<br/>= \\\\host.lan\\Data"]
        pty["storage/qemu.pty<br/>(serial capture)"]
        subgraph container["Dockur container (wootc-e2e-windows)"]
            qemu["QEMU<br/>TPM 2.0 + OVMF Secure Boot"]
            qga_sock["/run/shm/qga.sock<br/>(virtio-serial)"]
        end
    end
    subgraph vm["Guest VM"]
        win["Windows 11<br/>+ QEMU Guest Agent"]
        dep["wootc deployer<br/>(Fedora initramfs)"]
    end
    runner -->|"podman exec + qga.py"| qga_sock
    qga_sock <--> win
    win -->|"Copy-Item"| share
    qemu -->|"mon:stdio"| pty
    runner -->|"grep markers"| pty
    dep -.->|"serial console<br/>(kmsg markers)"| pty
```

Two control planes, one per OS:

| Guest state | Control plane | Direction |
|---|---|---|
| Windows | QGA (`guest-exec` PowerShell, `guest-file-read`) | bidirectional |
| Deployer (Linux initramfs) | Serial console only | **read-only** |

The deployer has no input path (container stdin is closed), which drives two
design rules: every failure must **reboot back to Windows** on its own, and
every diagnostic must be **pushed out** (serial kmsg markers + journal
persisted to NTFS) rather than pulled interactively.

## Secure Boot chain (validated)

```mermaid
flowchart TD
    fw["UEFI firmware (OVMF, Secure Boot on)"]
    bcd["BCD one-shot:<br/>{fwbootmgr} bootsequence → wootc entry<br/>path \\EFI\\fedora\\shimx64.efi"]
    shim["shimx64.efi<br/>(Microsoft-signed, Fedora build)"]
    grub["grubx64.efi<br/>(Fedora-signed)<br/>embedded prefix /EFI/fedora"]
    cfg["ESP:/EFI/fedora/grub.cfg<br/>linux /EFI/wootc/deployer-vmlinuz<br/>wootc.image=… console=ttyS0"]
    kernel["deployer-vmlinuz<br/>(Fedora Secure Boot Signer)"]
    initrd["deployer-initramfs.img<br/>(dracut, Fedora 44)"]
    winback["Windows Boot Manager<br/>(next boot: one-shot consumed)"]

    fw -->|"one-shot"| bcd --> shim -->|"verifies Fedora sig"| grub -->|"reads cfg at prefix"| cfg
    cfg --> kernel --> initrd
    initrd -->|"reboot -ff<br/>(success or failure)"| winback
```

Hard-won constraints baked into this design:

- **grub.cfg must live at `/EFI/fedora/grub.cfg`** — the signed GRUB's
  embedded prefix. A cfg in `\EFI\wootc\` is never read.
- **No external GRUB modules.** Under Secure Boot, GRUB refuses unsigned
  `.mod` files. `fat`, `part_gpt`, `search`, `linux`, `loopback` are
  embedded; **`ntfs` is not** — so GRUB can read the FAT32 ESP but never the
  NTFS volume. Deployer kernel + initramfs therefore live **on the ESP**
  (256 MB, holds the ~148 MB pair).
- **The kernel must be signed** (shim verifies it). The stock Fedora
  deployer kernel passes; an unsigned custom kernel would not.
- `$root` defaults to the device GRUB loaded from (the ESP) — no
  `set root=(hd0,gptN)` guessing.
- The BCD entry is the one `setup-wootc.ps1` created (GUID in
  `C:\wootc\install\bcd-guid.txt`), repointed from unsigned `wubildr.efi`
  to the shim. The runner re-arms this same GUID for the Phase-2 boot.

## Deployer internals

```mermaid
flowchart TD
    online["dracut initqueue/online hook<br/>(network up — may beat disk enumeration)"]
    wd["watchdog: sleep 2700 → force_reboot"]
    scan["scan for /wootc/disks/root.disk<br/>retry 24×5s + udevadm settle<br/>(ntfs3 ro probe of every partition)"]
    mnt["mount NTFS rw<br/>(dirty volume → clear error + fail)"]
    scratch["ext4 scratch loop on NTFS<br/>C:\\wootc\\cache\\deployer-scratch.img (30G)<br/>mounted at /var/fisherman-tmp<br/>binds: /var/lib/containers, /var/tmp"]
    preflight["registry pre-flight<br/>skopeo inspect docker://image<br/>(prints real DNS/TLS errors)"]
    loop["losetup root.disk → /dev/loopN"]
    fish["fisherman recipe.json<br/>partition → mkfs → podman pull →<br/>podman run bootc install to-filesystem"]
    verify["verification:<br/>inject 99wootc-boot dracut module,<br/>patch BLS entries, regen initramfs"]
    ok["VERIFICATION_SUMMARY marker<br/>umount all → reboot -ff → Windows"]
    fail["[FAIL] marker → journal+mounts to<br/>C:\\wootc\\logs\\ + sync →<br/>sleep 30 → force_reboot → Windows"]

    online --> wd
    online --> scan --> mnt --> scratch --> preflight --> loop --> fish --> verify --> ok
    scan -.->|"exhausted"| fail
    mnt -.->|"dirty NTFS"| fail
    preflight -.->|"unreachable"| fail
    fish -.->|"fatal"| fail
```

Why the scratch loop exists: the initramfs root is **ramfs** — a multi-GB
image pull there exhausts RAM (8 G VM). fisherman does its heavy I/O under
`/var/fisherman-tmp` (podman `--root`, OCI cache, bootc `/var/tmp` bind), and
overlay needs a real POSIX filesystem, so the deployer backs that path with
an ext4 loop file on the Windows partition and deletes it afterwards.

Initramfs contents that podman/fisherman hard-require (all missing from the
original build, each found by a failed run):

| Requirement | Failure it caused |
|---|---|
| `sfdisk`, `mkfs.fat`, `partprobe`, `blockdev`, `wipefs`, … | `fisherman: fatal: missing required host tool` |
| `/etc/containers/policy.json`, `registries.conf`, CA bundle | `podman pull` exit 125 (instant) |
| **`conmon` + `crun`** | `podman` exit 125: *could not find a working conmon binary* (also silently downgraded the overlay probe to VFS) |
| `truncate`, `install`, `mountpoint`, `udevadm`, `jq`, `sync` | script-level failures / lost logs |

## Failure & recovery loop (E2E debugging)

```mermaid
sequenceDiagram
    participant T as telengana (dev box)
    participant K as kanpur (host)
    participant W as Windows (QGA)
    participant D as Deployer (serial)

    T->>K: ssh + podman exec qga.py
    K->>W: guest-exec retry-deployer.ps1<br/>(refresh initramfs from share,<br/>re-arm BCD one-shot, reboot)
    W->>D: one-shot boots deployer
    D-->>K: kmsg markers on serial (qemu.pty)
    alt success
        D->>W: VERIFICATION_SUMMARY → reboot -ff
    else failure
        D->>W: journal → C:\wootc\logs + sync,<br/>[FAIL] marker → reboot -ff
        T->>W: qga read deployer-last-journal.log
        T->>K: patch /tmp/dep-root, repack initramfs<br/>(bsdtar newc + zstd, no rebuild)
    end
```

Operational invariants (violations cost a debug cycle each):

- **Never hard-kill the VM while the deployer has NTFS mounted rw** — the
  dirty bit sticks across normal Windows boots and blocks every later rw
  mount. Recovery: `Repair-Volume -DriveLetter C -OfflineScanAndFix` +
  reboot (autochk), verify with `fsutil dirty query C:`.
- **`reboot -f` is `systemctl reboot -f`** and hangs once dracut enters
  emergency mode (the gpt-auto root-device timeout fires ~45 s in, long
  before any deployer step finishes). Only `reboot -ff` / sysrq is safe.
- **stdout of a sourced initqueue hook does not reach the serial console**
  reliably — only `/dev/kmsg` writes and stderr do.
- The hook is **sourced under `set -e`**: capture exit codes as
  `status=0; cmd || status=$?`.

## Known limitation — Phase-2 Linux boot under Secure Boot

The runner's final step re-arms the wootc BCD entry to boot the *installed*
OS from inside `root.disk`. The wubildr design (GRUB loop-mounts root.disk
over NTFS) cannot work with the signed GRUB: `ntfs.mod` is unsigned and the
signed image doesn't embed it. Options, per SPEC §1.2:

1. **ESP kernel-sync** (systemd-boot-style): deployer copies the installed
   kernel+initramfs to the ESP and writes a GRUB entry with the loop-root
   cmdline; the installed initramfs (99wootc-boot) mounts NTFS itself via
   kernel ntfs3 — no GRUB NTFS needed. Fits the existing chain unchanged.
2. **MOK-enroll a custom signed GRUB** (wubildr with ntfs+loopback):
   preserves kernel-inside-root.disk loading but adds a one-time MokManager
   enrollment step.

(1) is recommended for the E2E and matches the OSTree sync-hook design
already specified for the systemd-boot path.
