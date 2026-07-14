# wootc — Windows bootc Installer (Specification)

wootc installs bootc-based Linux images from Windows without
repartitioning. The OS lives in a file (`root.disk`) on the Windows NTFS
partition. Uninstalling is deleting one file and one BCD entry.

**Prior art**: [WubiUEFI](https://github.com/hakuna-m/wubiuefi) proved the
dual-boot loop-file model with millions of users. wootc replaces Wubi's
Ubuntu-specific pipeline (ISO → casper → ubiquity → preseed) with
[fisherman](https://github.com/projectbluefin/fisherman) driving
[bootc install](https://github.com/containers/bootc). The result: smaller
downloads, no installer wizard, same system whether running from loop file
or real disk.

### Terminology

wootc has three distinct runtime phases, referred to throughout this spec:

| Phase | Runs where | Purpose |
|---|---|---|
| **Installer** | Windows (`wootc.exe`) | Downloads deployer, creates root.disk, configures BCD |
| **Deployer** | Initramfs (first boot) | Finds root.disk, runs fisherman, deploys bootc image |
| **Runtime** | Installed system (subsequent boots) | Full Linux desktop, loop-root boot via dracut module |

---

## 1. Boot Chain

### 1.1 Overview

```
                     ┌────────────────────────────────────────┐
                     │           WINDOWS INSTALLER            │
                     │  ─ Downloads deployer initramfs        │
                     │  ─ Creates C:\wootc\disks\root.disk    │
                     │  ─ Configures Windows Boot Manager     │
                     └──────────────────┬─────────────────────┘
                                        │ reboot
                                        ▼
┌───────────────────────────────────────────────────────────────┐
│                    FIRST BOOT (deployer)                       │
│                                                                │
│  Windows Boot Manager → bootloader → deployer initramfs       │
│                                                                │
│  deployer:                                                     │
│    ├─ Mount NTFS, find /wootc/disks/root.disk                  │
│    ├─ losetup root.disk                                        │
│    ├─ Run fisherman (partition → format → bootc install)       │
│    └─ Reboot                                                   │
└───────────────────────────────────┬───────────────────────────┘
                                    │ reboot
                                    ▼
┌───────────────────────────────────────────────────────────────┐
│                 SUBSEQUENT BOOTS (installed system)            │
│                                                                │
│  Windows Boot Manager → bootloader → kernel + initramfs       │
│                                                                │
│  initramfs:                                                    │
│    ├─ Mount NTFS, losetup root.disk                            │
│    ├─ Mount root from loop device                              │
│    └─ Pivot to real root                                       │
│                                                                │
│  System is identical to a native install.                      │
│  bootc update works normally.                                  │
└───────────────────────────────────────────────────────────────┘
```

### 1.2 Bootloader Options

wootc supports two bootloader paths:

| | GRUB2 | systemd-boot |
|---|---|---|
| NTFS access | Built-in (`ntfs.mod`) | None |
| Loopback mount | Built-in (`loopback.mod`) | None |
| Kernel location | Can load from inside root.disk | Must load from ESP |
| Maturity for this use case | Proven (Wubi, millions of users) | Requires kernel-sync mechanism |
| UKI support | Via chainload | Native |
| Secure Boot | Via shim | Native |

**GRUB2** is the default and proven path. It can mount NTFS and loop-mount
root.disk to load the installed system's kernel directly from inside the
disk image — no kernel sync needed.

**systemd-boot** is supported but requires a kernel-sync mechanism:
after deployment and after every `bootc update`, the new kernel+initrd
(or UKI) must be copied from inside root.disk to the ESP. This is handled
by a `bootc post-transaction` hook that fisherman installs during
deployment. The tradeoff: simpler bootloader (no GRUB complexity), native
UKI and Secure Boot support, but requires the sync hook.

#### GRUB2 boot flow (detailed)

```
Windows Boot Manager
  │  BCD entry: \EFI\wootc\wubildr\shimx64.efi
  │  (or grubx64.efi for non-Secure-Boot)
  ▼
GRUB2 core image (wubildr)
  │  Contains embedded wubildr-bootstrap.cfg
  │  Modules: ntfs, loopback, search, configfile, part_gpt
  ▼
wubildr.cfg
  │  search -f /wootc/disks/root.disk
  │  loopback loopw0 /wootc/disks/root.disk
  │
  ├─ [Installed OS found inside root.disk]
  │    configfile /boot/grub2/grub.cfg  (from inside loop device)
  │    → boots installed system normally
  │
  └─ [No OS found — first boot]
       configfile /wootc/install/grub.install.cfg
       → boots deployer initramfs
```

#### systemd-boot flow (detailed)

```
Windows Boot Manager
  │  BCD entry: \EFI\systemd\systemd-bootx64.efi
  ▼
systemd-boot
  │  Reads BLS entries from ESP:/loader/entries/
  │
  ├─ [Installed OS: wootc-<variant>.conf]
  │    linux   /wootc/vmlinuz
  │    initrd  /wootc/initramfs.img
  │    options root=WOOTC_LOOP loop=/wootc/disks/root.disk ...
  │    → boots installed system
  │
  └─ [No OS found — first boot: wootc-deployer.conf]
       linux   /wootc/deployer-vmlinuz
       initrd  /wootc/deployer-initramfs.img
       options wootc.image=ghcr.io/tuna-os/yellowfin:gnome ...
       → boots deployer
```

### 1.3 The Loop Root Challenge — Solved with Dracut Hooks

The critical piece inherited from Wubi: the initramfs must know how to
boot from a root filesystem that lives inside a loop device backed by an
NTFS-hosted file.

Wubi solved this with **lupin** — Ubuntu-specific initramfs-tools scripts.
For wootc, this is reimplemented as a dracut module. Dracut's hook-based
architecture lets us intercept the boot chain without rewriting the storage
stack — the module hooks into the `cmdline` and `mount` phases.

#### Kernel cmdline

```
root=UUID=<ntfs-partition-uuid> loop=/wootc/disks/root.disk ro quiet
```

#### Dracut module layout: `99wootc-boot`

Injected into the installed system at `/usr/lib/dracut/modules.d/99wootc-boot/`
by fisherman's post-install hook. Three files:

```
99wootc-boot/
├── module-setup.sh          # registers hooks, binaries, kernel modules
├── wootc-parse-cmdline.sh   # Hook 1: cmdline phase — intercepts root=
└── wootc-mount-loop.sh      # Hook 2: mount phase  — NTFS → loop → $NEWROOT
```

#### `module-setup.sh`

```bash
#!/bin/bash
# /usr/lib/dracut/modules.d/99wootc-boot/module-setup.sh

check() {
    return 0
}

depends() {
    echo "base"
}

installkernel() {
    instmods ntfs3 loop
}

install() {
    inst_hook cmdline 10 "$moddir/wootc-parse-cmdline.sh"
    inst_hook mount 99 "$moddir/wootc-mount-loop.sh"
    inst_multiple losetup mount mkdir modprobe blockdev sed sleep
}
```

#### `wootc-parse-cmdline.sh` (Hook 1)

Dracut natively tries to mount whatever block device is passed via `root=`.
If it sees `root=UUID=<ntfs-uuid>`, it will attempt to mount the Windows
partition directly as the Linux root, causing a kernel panic. This hook
intercepts the arguments, extracts the variables, and hijacks the root
handler so our custom mount hook takes control.

```bash
#!/bin/bash
# /usr/lib/dracut/modules.d/99wootc-boot/wootc-parse-cmdline.sh

LOOP_PATH=$(getarg loop=)

if [ -n "$LOOP_PATH" ]; then
    ORIG_ROOT=$(getarg root=)

    if [[ "$ORIG_ROOT" == UUID=* ]]; then
        WOOTC_HOST_UUID="${ORIG_ROOT#UUID=}"

        echo "wootc_host_uuid=\"$WOOTC_HOST_UUID\"" > /tmp/wootc.env
        echo "wootc_loop_path=\"$LOOP_PATH\""       >> /tmp/wootc.env

        # Hijack the standard root assignment. Setting it to 'wootc'
        # stops systemd/dracut from trying to mount the NTFS block directly.
        root="wootc"
        rootok=1
    fi
fi
```

#### `wootc-mount-loop.sh` (Hook 2)

Executes inside dracut's mount cycle. Waits for the Windows partition via
udev, mounts it read-write, binds root.disk to a loop device, and maps
the result to `$NEWROOT` (/sysroot).

```bash
#!/bin/bash
# /usr/lib/dracut/modules.d/99wootc-boot/wootc-mount-loop.sh

if [ "$root" = "wootc" ]; then
    if [ -f /tmp/wootc.env ]; then
        . /tmp/wootc.env
    fi

    if [ -z "$wootc_host_uuid" ] || [ -z "$wootc_loop_path" ]; then
        die "wootc: missing host UUID or loop path"
    fi

    modprobe ntfs3 2>/dev/null
    modprobe loop 2>/dev/null

    HOST_DEV="/dev/disk/by-uuid/$wootc_host_uuid"

    if [ ! -b "$HOST_DEV" ]; then
        local i=0
        while [ ! -b "$HOST_DEV" ] && [ $i -lt 15 ]; do
            sleep 0.5
            i=$((i+1))
        done
    fi

    if [ ! -b "$HOST_DEV" ]; then
        die "wootc: host partition $HOST_DEV did not appear"
    fi

    HOST_MNT="/sysroot/host"
    mkdir -p "$HOST_MNT"

    # Mount the host NTFS partition read-write.
    # If Windows was not shut down cleanly, ntfs3 will refuse rw mount.
    # Rather than forcing (which risks corruption), we tell the user to
    # boot Windows once and perform a full shutdown.
    if ! mount -t ntfs3 -o rw,nobarrier,async "$HOST_DEV" "$HOST_MNT"; then
        die "wootc: cannot mount host NTFS partition rw. " \
            "Windows may not have been shut down cleanly. " \
            "Please boot Windows once, perform a full shutdown " \
            "(not restart), and try again."
    fi

    FULL_LOOP_PATH="$HOST_MNT/$wootc_loop_path"
    FULL_LOOP_PATH=$(echo "$FULL_LOOP_PATH" | sed 's/\/\//\//g')

    if [ ! -f "$FULL_LOOP_PATH" ]; then
        die "wootc: root.disk not found at $FULL_LOOP_PATH"
    fi

    LOOP_DEV=$(losetup -f --show "$FULL_LOOP_PATH")
    if [ -z "$LOOP_DEV" ]; then
        die "wootc: losetup failed"
    fi

    blockdev --setra 2048 "$LOOP_DEV"

    if ! mount -o rw,noatime "$LOOP_DEV" "$NEWROOT"; then
        die "wootc: failed to mount loop root to \$NEWROOT"
    fi

    rootok=1
fi
```

#### The Remount Trap

Standard Linux init scripts often attempt a generic root remount
(`mount -o remount,rw /`) late in the boot sequence. Because the real
root is nested inside a loop device backed by a secondary mount context
(`/sysroot/host`), a standard remount command cannot reach through both
layers and will fail silently or break the root filesystem.

To prevent this, fisherman's post-install hook writes an fstab entry
that preserves the nesting hierarchy:

```
# /etc/fstab inside root.disk
/host/wootc/disks/root.disk  /  auto  defaults,noatime,loop  0  0
```

This tells the installed system: "the root device is the loop file on
the host, not a block device." Standard remounts resolve correctly
through the loop layer.

#### NTFS Mount Mode: Why Read-Write

Unlike the deployer (which can safely mount NTFS read-only since it only
reads root.disk to set up the loop device), the installed system **must**
write to its root filesystem. If the host NTFS is mounted read-only, the
loop device inherits the physical write block — every write to the Linux
root fails at the block layer.

If ntfs3 refuses to mount (because Windows was hibernated or not shut
down cleanly), wootc directs the user to boot Windows once and perform
a full shutdown. It does **not** use `mount -o force` — writing to a
dirty NTFS volume risks silent corruption of the Windows filesystem.

---

## 2. Deployer Initramfs

The deployer is a minimal Linux initramfs (~200MB) that runs once to
populate root.disk with the chosen bootc image.

### 2.1 Contents

| Component | Purpose |
|---|---|
| Fedora 44 kernel | Boots on wide range of hardware |
| [fisherman](https://github.com/projectbluefin/fisherman) | Go binary: partition, format, bootc install to-filesystem |
| podman + skopeo | Pull OCI images, run bootc container |
| ntfs3 (in-kernel) | Mount Windows NTFS partition (no FUSE overhead) |
| dracut + network modules | DHCP, DNS |

### 2.2 Flow

```
1. Kernel boots, init runs
2. Load kernel modules (loop, ntfs3)
3. Start DHCP on first active interface
4. Parse kernel cmdline:
     wootc.image=ghcr.io/tuna-os/yellowfin:gnome   (required)
     wootc.hostname=tunaos                           (optional)
     wootc.filesystem=xfs|btrfs|ext4                 (optional, per-distro default)
     wootc.flatpaks=org.mozilla.firefox,...          (optional)
     wootc.luks=none|tpm2-luks|luks-passphrase       (optional)
     wootc.luks-passphrase=...                        (optional)
     wootc.debug                                      (optional)
5. Find NTFS partition containing /wootc/disks/root.disk
6. Mount NTFS read-write at /mnt/ntfs (in-kernel ntfs3 driver, Linux 5.15+)
7. losetup -fP /mnt/ntfs/wootc/disks/root.disk
8. Write fisherman recipe JSON → /tmp/recipe.json
9. Run: fisherman /tmp/recipe.json
10. losetup -d, umount
11. reboot
```

### 2.3 Filesystem Selection

wootc supports three root filesystems. The default is chosen based on
the target distro's native preference:

| Distro family | Default FS | Reason |
|---|---|---|
| Fedora, Rawhide, Arch, openSUSE, Gentoo | **btrfs** | Native support, compression, snapshots |
| AlmaLinux, CentOS Stream, RHEL (EL10) | **xfs** | Red Hat's default; Btrfs not shipped |
| Ubuntu, Debian | **ext4** | Lowest common denominator, widely compatible |

The user can override via `wootc.filesystem=btrfs|xfs|ext4` on the kernel
cmdline. The deployer passes this through to the fisherman recipe, which
handles `mkfs.<type>` and the correct mount options.

The dracut mount hook auto-detects the filesystem type from the
loop device (`mount` without `-t`), so the installed system boots
correctly regardless of which filesystem was chosen at deploy time.

**Btrfs** is recommended where available for its snapshot/rollback
integration with bootc's atomic update model, transparent zstd
compression (saves space inside the loop file), and reflink copy
(accelerates OCI layer extraction).

### 2.4 Fisherman Recipe

Generated at deploy time from kernel cmdline args:

```json
{
  "disk": "/dev/loop0",
  "filesystem": "xfs",
  "composeFsBackend": false,
  "bootloader": "grub2",
  "encryption": {
    "type": "none"
  },
  "image": "ghcr.io/tuna-os/yellowfin:gnome",
  "hostname": "tunaos",
  "flatpaks": ["org.mozilla.firefox"],
  "slurpWallpapers": true
}
```

The `image` field is the OCI reference for the target OS. fisherman
handles:
- **CheckImage**: compares remote vs local digest, determines if pull needed
- **Pull**: `podman pull` to containers-storage
- **Install**: `podman run --privileged <image> bootc install to-filesystem /target`
- **Post**: flatpak copy, hostname write, Plymouth args, LUKS args, Bluetooth/WiFi sync, audio config, cache warm, fstrim/remount-ro/fsfreeze finalize

### 2.5 LUKS Encryption

wootc supports LUKS encryption of the root filesystem inside root.disk.
This protects the Linux system even though the host NTFS partition is
unencrypted — if the disk is stolen, the loop file yields only encrypted
blocks.

fisherman already supports three LUKS modes (passed via the recipe's
`encryption` field):

| Mode | Key source | UX |
|---|---|---|
| `luks-passphrase` | User-chosen passphrase | Prompted on every boot |
| `tpm2-luks` | TPM2 chip | Automatic — no prompt |
| `tpm2-luks-passphrase` | TPM2 + fallback passphrase | Auto, with recovery passphrase |

For loop-file deployments, `tpm2-luks` is the recommended mode:
the TPM2 chip on the motherboard unlocks the LUKS volume automatically.
If the disk is moved to another machine, the TPM measurement changes
and the volume stays locked.

**Deployer cmdline for LUKS:**

```
wootc.luks=tpm2-luks
wootc.luks-passphrase=hunter2    # only for passphrase modes
```

The deployer writes these into the fisherman recipe's `encryption`
field. fisherman handles `luksFormat`, `luksOpen`, `cryptsetup`,
and injects `rd.luks.name=<UUID>=root` into every BLS boot entry.

The dracut `99wootc-boot` mount hook works transparently with LUKS:
by the time the mount hook runs, systemd has already activated the
LUKS volume (via `rd.luks.name` in the kernel cmdline), and the loop
device exposes the decrypted block device.

For TPM2 modes on loop files: the TPM2 enrollment happens inside the
deployer initramfs where `/dev/tpm0` is accessible. fisherman's
`luks.EnrollTPM2()` binds the LUKS key to PCR 7 (Secure Boot state).
If Secure Boot is not available, PCR 0+1 (firmware + configuration)
fallback is used.

### 2.6 Post-deployment: loop-root dracut module

After bootc install to-filesystem completes, fisherman runs a post-install
hook that injects the `99wootc-boot` dracut module into the installed
system. This module ensures subsequent boots can mount the root filesystem
from the NTFS-hosted loop file.

The module is installed at `/usr/lib/dracut/modules.d/99wootc-boot/` inside
the target and dracut is regenerated to include it in the initramfs.

---

## 3. Windows Installer

Adapted from WubiUEFI's Python/Win32 application. Reuses the existing
BCD manipulation, GRUB core image creation, ESP file management, and
sparse file creation — replaces the ISO download and preseed generation.

### 3.1 Changes from WubiUEFI

| WubiUEFI | wootc |
|---|---|
| Downloads Ubuntu ISO (~4GB) | Downloads deployer kernel+initrd (~200MB) |
| Extracts vmlinuz+initrd from ISO via 7z | Uses deployer files directly |
| Writes preseed.cfg for ubiquity | Writes GRUB env or BLS entry with image ref |
| Shows Ubuntu releases | Shows TunaOS variant catalog |
| Verifies ISO MD5/SHA | Verifies initramfs checksum |
| `C:\ubuntu\` | `C:\wootc\` |

### 3.2 User Flow

1. User runs `wootc.exe`
2. Selects target image from catalog:
   ```
   ┌──────────────────────────────────────────┐
   │ Choose your TunaOS variant:              │
   │                                           │
   │ 🐠 Yellowfin GNOME    (AlmaLinux Kitten) │
   │ 🎣 Bonito KDE          (Fedora 44)       │
   │ 🚀 Marlin GNOME        (Arch Linux)      │
   │ ...                                       │
   │                                           │
   │ Disk size: [___40___] GB                  │
   │ Hostname:   [___tunaos___]                │
   │                                           │
   │ [Install]  [Cancel]                       │
   └──────────────────────────────────────────┘
   ```
3. Selects disk size (default 40GB), hostname
4. wootc.exe:
   - Downloads deployer kernel+initrd to `C:\wootc\install\`
   - Creates sparse `C:\wootc\disks\root.disk` (Windows API: CreateFileW,
     SetFilePointerEx, SetEndOfFile, SetFileValidData)
   - Copies GRUB EFI files to ESP
   - If systemd-boot: copies systemd-boot EFI to ESP
   - Runs bcdedit to add Windows Boot Manager entry
   - Writes `grub.install.cfg` or BLS entry with kernel cmdline
5. User reboots, selects "wootc" from Windows boot menu
6. First boot runs deployer (~5-15 min depending on network)
7. Second boot: full TunaOS desktop

### 3.5 Windows Hazard Mitigation

The Windows installer must detect and mitigate silent failure modes
before the user reboots.

#### BitLocker: The Fundamental Constraint

wootc stores `root.disk` on the Windows NTFS partition. The installed
system must mount that NTFS partition read-write on **every boot** to
access the loop device.

BitLocker encrypts the NTFS volume at the sector level. Once Windows
Boot Manager hands off to Linux, the decrypted NTFS filesystem is no
longer accessible — Linux sees only encrypted sectors. Windows Boot
Manager cannot expose a decrypted NTFS volume to a non-Windows boot
chain; that's inherent to how BitLocker and the TPM trust chain work.

Linux *can* unlock BitLocker volumes via `cryptsetup` or `dislocker`
if the user provides a recovery key or password — but this would mean
prompting for a BitLocker password on every Linux boot, which defeats
the seamless dual-boot experience wootc aims for.

**wootc supports three modes:**

| Mode | C: status | root.disk location | UX |
|---|---|---|---|
| **Normal** | No BitLocker | `C:\wootc\disks\root.disk` | Best — just works |
| **BitLocker** | BitLocker-protected C: | Separate unencrypted NTFS partition (e.g. `D:\wootc\disks\root.disk`) | Good — user picks or creates a data partition |
| **Native** | Any | Native Linux partition (post-migration) | Best — no NTFS dependency |

**Normal mode detection** — the installer queries volume status:

```cmd
manage-bde -status C:
```

| BitLocker status | Action |
|---|---|
| Fully Decrypted | Proceed in Normal mode. |
| Protection On | Present BitLocker mode options (see below). |
| Encryption In Progress | Hard block. "Windows is encrypting C:. Wait for completion." |

**BitLocker mode UX — auto-create a data partition:**

```
┌──────────────────────────────────────────────────────┐
│ BitLocker detected on C:                              │
│                                                       │
│ wootc cannot store Linux on an encrypted drive.       │
│                                                       │
│ (Recommended) Create a shared data partition           │
│     Shrink C: by 60 GB, create D: for root.disk       │
│     C: stays BitLocker-protected                      │
│     D: is unencrypted, shared between both OSes       │
│                                                       │
│ Choose existing partition                              │
│     Select an unencrypted drive you already have      │
│     Available: E: (Backup, 200 GB free)               │
│                                                       │
│ Suspend BitLocker temporarily                          │
│     Protection resumes on next Windows boot.          │
│     ⚠ Only works for the install — you'll need       │
│       a data partition for everyday dual-booting.     │
│                                                       │
│ [Create Partition]  [Choose Drive]  [Suspend]  [Cancel]│
└──────────────────────────────────────────────────────┘
```

**Auto-create implementation** — the installer uses Windows disk
management to shrink C: non-destructively:

```powershell
# Query maximum shrink size
$partition = Get-Partition -DriveLetter C
$maxShrink = Get-PartitionSupportedSize -DriveLetter C
$targetSize = 60GB  # default for root.disk + breathing room

if ($maxShrink.SizeMax - $maxShrink.SizeMin -gt ($targetSize * 1.1GB)) {
    # Shrink C: by targetSize
    Resize-Partition -DriveLetter C -Size ($maxShrink.SizeMax - ($targetSize * 1GB))
    
    # Create new partition in freed space
    $newPart = New-Partition -DiskNumber $partition.DiskNumber `
        -UseMaximumSize -DriveLetter D
    
    # Format as NTFS
    Format-Volume -DriveLetter D -FileSystem NTFS `
        -NewFileSystemLabel "wootc-data" -Confirm:$false
    
    Write-Host "Created D: ($targetSize GB) for wootc"
}
```

This is non-destructive: Windows Disk Management has been doing this
safely since Windows 7. The freed space becomes a new partition visible
to both Windows and Linux.

Per-directory encryption (Windows 11 Home default) does not block
wootc — only full-volume BitLocker requires these options.

#### Fast Startup Mitigation

Windows Fast Startup doesn't shut down; it hibernates the kernel and
marks NTFS volumes as "dirty." The Linux ntfs3 driver will refuse to
mount read-write, causing the deployer loop setup to fail.

**Mitigation** — the installer disables Fast Startup programmatically:

```cmd
REG ADD "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f
```

On next shutdown, Windows performs a full shutdown, leaving NTFS clean.
This is non-destructive and safe — it only disables the hibernation-on-
shutdown behaviour. The user can re-enable it later from Windows power
settings if needed.

**Alternative** (more aggressive): `powercfg /h off` disables hibernation
entirely, ensuring pristine NTFS state on every reboot. Only used if the
registry approach fails or on Windows editions that don't respect the
registry key.

### 3.6 NTFS Fragmentation Prevention

When wootc.exe creates `root.disk` as a sparse file, Windows allocates
space on demand. When fisherman streams gigabytes of container layers into
that file, the clusters will be scattered across the physical disk —
especially on spinning drives or fragmented SSDs. Because every I/O to the
installed system passes through both the loop layer and the NTFS cluster
mapping, fragmentation can silently bottleneck disk performance.

**Mitigation** — pre-allocate contiguous clusters during file creation:

```c
// Instead of: SetFilePointerEx + SetEndOfFile (sparse, lazy allocation)
// Use: SetFileValidData after SetEndOfFile to force immediate allocation

HANDLE h = CreateFileW(path, GENERIC_WRITE, 0, NULL,
                        CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);

LARGE_INTEGER size;
size.QuadPart = (LONGLONG)size_gb * 1024 * 1024 * 1024;
SetFilePointerEx(h, size, NULL, FILE_BEGIN);
SetEndOfFile(h);
SetFileValidData(h, size.QuadPart);  // force pre-allocation
CloseHandle(h);
```

`SetFileValidData` requires `SE_MANAGE_VOLUME_NAME` privilege (admin).
wootc.exe already runs elevated, so this is available. On SSDs, the
performance difference is minimal (random access is fast). On spinning
disks, contiguous pre-allocation can be 2-5x faster for sustained I/O.

**Fallback**: If contiguous space isn't available (disk too full), fall
back to the sparse creation path with a warning: "Disk is fragmented.
Performance may be reduced. Consider freeing space and defragmenting
before installing."

The Windows installer presents available images from `data/images.json`
— the same catalog format used by fisherman and tuna-installer:

```json
{
  "TunaOS": {
    "yellowfin": {
      "name": "Yellowfin",
      "emoji": "🐠",
      "base": "AlmaLinux Kitten 10",
      "desktops": {
        "gnome": {
          "name": "GNOME",
          "image": "ghcr.io/tuna-os/yellowfin:gnome",
          "description": "Modern GNOME desktop on Enterprise Linux"
        }
      }
    }
  }
}
```

The catalog can be overridden at `C:\wootc\images.json` for custom
deployments.

### 3.4 Windows File Layout

```
C:\wootc\
├── install\
│   ├── deployer-vmlinuz       # deployer kernel
│   ├── deployer-initramfs.img # deployer initramfs
│   ├── grub.install.cfg       # first-boot GRUB menu (GRUB2 path)
│   ├── wubildr.cfg            # main GRUB config (GRUB2 path)
│   └── wubildr-bootstrap.cfg  # GRUB bootstrap (GRUB2 path)
├── disks\
│   └── root.disk              # OS virtual disk (sparse, NTFS)
├── images.json                # image catalog (optional override)
└── uninstall.exe              # removes BCD entry + C:\wootc\

ESP:\EFI\wootc\                 # GRUB2 path
├── wubildr\
│   ├── shimx64.efi            # Secure Boot shim
│   ├── grubx64.efi            # GRUB2 EFI binary
│   └── wubildr.cfg            # embedded in core image
├── deployer-vmlinuz            # kernel (systemd-boot path only)
└── deployer-initramfs.img      # initramfs (systemd-boot path only)

ESP:\EFI\systemd\               # systemd-boot path
└── systemd-bootx64.efi
```

---

## 4. Migration: Transparent Passthrough + Staged Native Conversion

wootc's defining feature is **transparent passthrough**: instead of
immediately copying everything, the installed system uses Windows
resources directly. Documents, Pictures, Downloads, Steam libraries,
and browser profiles are accessible from day one via bind mounts into
the Linux home directory. No long initial copy. No "where are my files?"

Weeks or months later, the user can choose to convert to native Linux
storage — one category at a time, at their own pace.

### 4.1 Transparent Passthrough (Day One)

On first boot into the installed system, the `99wootc-boot` dracut module
mounts the Windows NTFS partition at `/sysroot/host`. A systemd service
(`wootc-passthrough.service`) then creates bind mounts:

```
/host/Users/<name>/Documents    →  /home/<name>/Documents
/host/Users/<name>/Pictures     →  /home/<name>/Pictures
/host/Users/<name>/Downloads    →  /home/<name>/Downloads
/host/Users/<name>/Music        →  /home/<name>/Music
/host/Users/<name>/Videos       →  /home/<name>/Videos
/host/Users/<name>/Desktop      →  /home/<name>/Desktop
```

The user sees their Windows files immediately inside their Linux home
directory. No copy. No import wizard. Files are writable from Linux
(via the rw NTFS mount).

**Steam libraries** are detected and reused in-place:

```
/host/Program Files (x86)/Steam/steamapps/  →  detected by Steam Linux
```

The system writes a `libraryfolders.vdf` that points to the Windows
Steam library. Games appear immediately — no re-download. Proton handles
compatibility automatically.

**Browser profiles** are detected and offered for import:

| Windows browser | Linux equivalent | What migrates |
|---|---|---|
| Chrome | Chrome (Flatpak) | bookmarks, history, passwords (with consent) |
| Edge | Chrome (Flatpak) | bookmarks, history |
| Firefox | Firefox (Flatpak) | bookmarks, history, passwords, extensions |

### 4.2 Staged Native Conversion

At any point, the user can open the wootc migration panel and convert
individual categories to native Linux storage:

```
┌──────────────────────────────────────────────────┐
│ wootc Migration                                   │
│                                                   │
│ ☑ Windows Documents → Linux    (12.3 GB)  [Done] │
│ ☑ Steam libraries → Linux      (45.1 GB)  [Done] │
│ ☐ Browser profile              (0.2 GB)   [Move] │
│ ☐ Pictures → Linux             (8.1 GB)   [Move] │
│ ☐ Keep Windows dual-boot                     [ ] │
│                                                   │
│ Stage 5: Remove Windows       (frees 189 GB) [ → ]│
└──────────────────────────────────────────────────┘
```

Each stage is independent and reversible (before deletion):

| Stage | Action | Reversible? |
|---|---|---|
| 1. Use Windows Documents | Bind-mount into `$HOME` | Yes (undo bind mount) |
| 2. Use Steam libraries | Detect and reference in-place | Yes (nothing changed) |
| 3. Import browser profile | Copy bookmarks/passwords/history | Yes (delete imported profile) |
| 4. Convert Documents to native | Copy files, update bind mount | Yes (files still on NTFS until stage 6) |
| 5. Convert home to native | Move `$HOME` to native Linux filesystem | Yes (snapshot rollback) |
| 6. Remove Windows | Delete Windows partition, expand Linux | **No** (Windows is gone) |

### 4.3 App Detection

During installation, the deployer scans the Windows partition for
installed applications and offers Linux equivalents via Flatpak:

| Windows app detected | Linux equivalent |
|---|---|
| Visual Studio Code | `com.visualstudio.code` |
| Discord | `com.discordapp.Discord` |
| Spotify | `com.spotify.Client` |
| Steam | `com.valvesoftware.Steam` |
| Firefox | `org.mozilla.firefox` |
| Chrome | `com.google.Chrome` |
| OBS Studio | `com.obsproject.Studio` |
| GIMP | `org.gimp.GIMP` |
| VLC | `org.videolan.VLC` |

These are added to the fisherman recipe's `flatpaks` field and
pre-installed during deployment.

### 4.4 Windows-Style Mode

On first login, the system can optionally adopt the Windows host's
aesthetics to reduce the visual shock of switching OS:

- Same wallpaper (extracted via fisherman's Slurp)
- Same accent color
- Same hostname
- Same timezone and keyboard layout
- Browser set to the same homepage

This is a "first boot only" mode. The user can switch to the distro's
native defaults at any time from the settings panel.

### 4.5 The bootc advantage

Throughout this entire migration, the OS itself never changes. The same
OCI image boots whether the root filesystem is inside `root.disk` on NTFS
or on a native Btrfs partition. Migration is deploying the same image to
real disk and updating fstab. No reinstall, no reconfiguration.

---

## 5. Uninstall

wootc is fully reversible. The uninstall flow adapts based on where
root.disk was stored.

### 5.1 Normal Uninstall (root.disk on C:)

```
┌──────────────────────────────────────────────┐
│ wootc Uninstaller                             │
│                                               │
│ This will:                                    │
│  - Remove the wootc boot entry from Windows   │
│  - Delete C:\wootc\ (including root.disk)     │
│  - Remove GRUB/systemd-boot from ESP          │
│                                               │
│ All Linux data will be permanently deleted.   │
│                                               │
│ [Uninstall]  [Cancel]                         │
└──────────────────────────────────────────────┘
```

### 5.2 Partition-Aware Uninstall (root.disk on D:)

When wootc created a separate partition (BitLocker mode or user choice),
the uninstaller detects this and offers to clean it up:

```
┌───────────────────────────────────────────────────┐
│ wootc Uninstaller                                  │
│                                                    │
│ wootc is installed on drive D: (wootc-data).       │
│                                                    │
│ This will:                                         │
│  ☑ Remove the wootc boot entry from Windows        │
│  ☑ Delete D:\wootc\ (including root.disk)          │
│  ☑ Remove GRUB from ESP                            │
│                                                    │
│ D: was created by wootc and only contains Linux.   │
│                                                    │
│  ☐ Also remove D: and return space to C:           │
│      This will extend C: by 60 GB                  │
│                                                    │
│ [Uninstall + Remove Partition]  [Uninstall Only]   │
│ [Cancel]                                           │
└───────────────────────────────────────────────────┘
```

**Detection logic** — the uninstaller inspects the partition before
offering cleanup:

```powershell
# Check if D: was created by wootc (only contains wootc directory)
$items = Get-ChildItem D:\ -Force | Where-Object {
    $_.Name -ne '$RECYCLE.BIN' -and
    $_.Name -ne 'System Volume Information' -and
    $_.Name -ne 'wootc'
}

if ($items.Count -eq 0) {
    # D: was created by wootc and contains only wootc data.
    # Offer to remove the partition and extend C: back.
    $wasCreatedByWootc = $true
}
```

**Partition removal + C: extension:**

```powershell
# 1. Remove D: partition
$partition = Get-Partition -DriveLetter D
$diskNumber = $partition.DiskNumber
Remove-Partition -DriveLetter D -Confirm:$false

# 2. Extend C: into the freed space
$cPartition = Get-Partition -DriveLetter C
Resize-Partition -DriveLetter C -Size ($cPartition.Size + $partition.Size)
```

If D: contains other user files (not just wootc), the "remove D:"
option is hidden — the user only sees "Uninstall [Keep D:]".

### 5.3 ESP Cleanup

Both modes clean the EFI System Partition:

```powershell
# Remove GRUB2
Remove-Item "$($esp.DriveLetter):\EFI\wootc" -Recurse -Force -ErrorAction SilentlyContinue

# Remove systemd-boot (if used)
Remove-Item "$($esp.DriveLetter):\EFI\systemd" -Recurse -Force -ErrorAction SilentlyContinue
```

Implementation: `wubi.exe` already has an uninstall mode that removes BCD
entries and deletes the installation directory. wootc extends this with
partition detection, ESP cleanup, and optional partition undo.

---

## 6. License

The Windows installer component (`windows/`) is adapted from
[WubiUEFI](https://github.com/hakuna-m/wubiuefi) which is licensed under
**GPL-2.0**. Any code derived from or incorporating WubiUEFI source must
retain the GPL-2.0 license.

The deployer initramfs and GRUB configuration are original work and
licensed under **MIT**.

Fisherman, bootc, bootupd, podman, and skopeo are each distributed under
their own licenses (Apache-2.0 for all listed). These are linked or
executed as separate binaries at runtime, not incorporated into wootc
source. This architectural separation — GPL-2.0 Windows installer
communicating with an MIT-licensed deployer over a process boundary
(WinRM → initramfs) — ensures clean license boundaries.

## 7. Key Dependencies

| Project | Role | License |
|---|---|---|
| [WubiUEFI](https://github.com/hakuna-m/wubiuefi) | Windows installer, BCD, GRUB core images | GPL-2.0 |
| [fisherman](https://github.com/projectbluefin/fisherman) | Disk partitioning, bootc install, data slurp | Apache-2.0 |
| [bootc](https://github.com/containers/bootc) | Container-native OS install and updates | Apache-2.0 |
| [bootupd](https://github.com/coreos/bootupd) | Bootloader installation (invoked by bootc) | Apache-2.0 |
| [podman](https://github.com/containers/podman) | OCI image pull and container execution | Apache-2.0 |
| [skopeo](https://github.com/containers/skopeo) | Image inspection, OCI layout export | Apache-2.0 |

---

## 8. Project Structure

```
wootc/
├── SPEC.md                    ← THIS FILE — consolidated specification
├── README.md                  ← user-facing overview
├── deployer/
│   ├── Containerfile          ← builds deployer initramfs (~200MB)
│   ├── deploy.sh              ← deployer script (finds NTFS → losetup → fisherman)
│   ├── init                   ← PID 1 init script
│   ├── module-setup.sh        ← dracut module for wootc-deploy
│   └── 99wootc-boot/          ← dracut module injected into installed system
│       ├── module-setup.sh
│       └── wootc-boot.sh      ← loop-root mount logic for subsequent boots
├── grub/
│   ├── wubildr-bootstrap.cfg  ← GRUB entry point (embedded in core image)
│   ├── wubildr.cfg            ← main GRUB config (dual-mode: boot OS or deployer)
│   └── grub.install.cfg       ← first-boot menu → boots deployer
├── windows/                    ← adaptation of wubiuefi's Python/Win32 app
│   └── (to be built)
├── fisherman/                  ← git submodule: github.com/projectbluefin/fisherman
└── .gitignore
```

---

## 9. Open Questions

1. **Secure Boot with GRUB2**: WubiUEFI uses shim for Secure Boot. wootc
   inherits this for the GRUB2 path. systemd-boot has native Secure Boot
   support via signed UKIs. Signing pipeline and key management TBD.

2. **ARM64 Windows**: WubiUEFI supports x86_64 only. ARM64 Windows devices
   (Surface Pro X, etc.) use a completely different boot chain. Deferred.

3. **systemd-boot kernel sync hook**: The `bootc post-transaction` hook
   that copies kernels from inside root.disk to the ESP needs to handle
   the case where root.disk is not yet mounted at hook execution time.
   May need to be a systemd path unit instead.

4. **root.vhdx vs root.disk**: Consider using VHDX format instead of raw
   disk images. Windows tooling natively understands VHD/VHDX for
   mounting, backup, and resizing. Linux supports them well. A user could
   mount their Linux disk from within Windows for recovery. Deferred to
   post-MVP.

5. **Integrity verification**: OCI digest, deployer initramfs checksum,
   kernel checksum, and root.disk integrity should be verified before
   every boot. Corruption should trigger a repair path rather than a
   kernel panic. Deferred.

6. **Migration reversibility**: Snapshots before each migration stage
   would allow the user to undo. Btrfs snapshots inside root.disk make
   this possible. Deferred until btrfs is the default.

## 10. Build & Test

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/tuna-os/wootc.git
cd wootc

# Build deployer initramfs (from repo root)
podman build -f deployer/Containerfile -t wootc-deployer .
mkdir -p deployer/out
podman run --rm --entrypoint /bin/cat localhost/wootc-deployer \
    /out/initramfs.img > deployer/out/initramfs.img
podman run --rm --entrypoint /bin/cat localhost/wootc-deployer \
    /out/vmlinuz > deployer/out/vmlinuz

# Full e2e test (requires KVM)
cd tests/e2e && ./run-e2e.sh

# CI-only tests (no KVM needed)
shellcheck --severity=warning deployer/*.sh deployer/99wootc-boot/*.sh tests/e2e/run-e2e.sh
```
