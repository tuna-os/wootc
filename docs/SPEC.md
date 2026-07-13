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
    instmods ntfs3 loop xfs
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

    # CRITICAL: must mount read-write. If the host is ro, the loop
    # device inherits the physical write block, rendering the guest
    # OS filesystem read-only.
    if ! mount -t ntfs3 -o rw,nobarrier,async "$HOST_DEV" "$HOST_MNT"; then
        warn "wootc: standard ntfs3 mount failed (dirty partition?). Trying force..."
        if ! mount -t ntfs3 -o rw,force "$HOST_DEV" "$HOST_MNT"; then
            die "wootc: cannot mount host NTFS partition rw"
        fi
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

    if ! mount -t xfs -o rw,noatime "$LOOP_DEV" "$NEWROOT"; then
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
/host/wootc/disks/root.disk  /  xfs  defaults,noatime,loop  0  0
```

This tells the installed system: "the root device is the loop file on
the host, not a block device." Standard remounts resolve correctly
through the loop layer.

#### NTFS Mount Mode: Why Read-Write

Unlike the deployer (which can safely mount NTFS read-only since it only
reads root.disk to set up the loop device), the installed system **must**
write to its root filesystem. If the host NTFS is mounted read-only, the
loop device inherits the physical write block — every write to the Linux
root fails at the block layer. The `force` recovery mount handles the
case where Windows left the volume marked dirty (Fast Startup).

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
     wootc.flatpaks=org.mozilla.firefox,...          (optional)
     wootc.debug                                      (optional)
5. Find NTFS partition containing /wootc/disks/root.disk
6. Mount NTFS read-write at /mnt/ntfs (in-kernel ntfs3 driver, Linux 5.15+)
7. losetup -fP /mnt/ntfs/wootc/disks/root.disk
8. Write fisherman recipe JSON → /tmp/recipe.json
9. Run: fisherman /tmp/recipe.json
10. losetup -d, umount
11. reboot
```

### 2.3 Fisherman Recipe

Generated at deploy time from kernel cmdline args:

```json
{
  "disk": "/dev/loop0",
  "filesystem": "xfs",
  "composeFsBackend": false,
  "bootloader": "grub2",
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

### 2.4 Post-deployment: loop-root dracut module

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

The Windows installer must detect and mitigate two silent failure modes
before the user ever reboots. If left unchecked, both cause confusing
first-boot failures.

#### BitLocker Detection

If the Windows C: drive is encrypted with BitLocker, the deployer
initramfs will see the NTFS volume as random noise and fail to find
`/wootc/disks/root.disk`.

**Detection** — the installer queries volume status before creating any files:

```cmd
manage-bde -status C:
```

**Logic:**

| BitLocker status | Action |
|---|---|
| Protection On | **Hard block.** Show UI: "BitLocker is enabled on C:. wootc requires an unencrypted NTFS volume. Suspend BitLocker in Windows Settings, then retry." |
| Encryption In Progress | **Hard block.** Show UI: "Windows is currently encrypting C:. Wait for encryption to complete or cancel it, then retry." |
| Protection Off / Fully Decrypted | Proceed normally. |

Per-directory encryption (the default on modern Windows 11 Home) does
not block wootc — only full-volume BitLocker does.

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

## 4. Migration Path: wootc → Native Linux

wootc is a reversible on-ramp. Users who decide to stay can graduate to a
proper native install — reclaiming the full disk, removing Windows, and
bringing their data.

### 4.1 The bootc advantage

The system is defined by the OCI image, not the installation method. A
wootc system running from `root.disk` is identical to the same image
installed to a real partition. Migration is deploying the same image to
real disk and moving user data.

### 4.2 Three-phase migration

#### Phase 1: Assessment

The migration tool (run from within the wootc system before repartitioning)
scans the Windows NTFS partition and presents a summary:

```
┌──────────────────────────────────────────────┐
│ Windows partition: /dev/nvme0n1p3 (NTFS)     │
│                                               │
│ Total:    475 GB                              │
│ Used:     189 GB                              │
│                                               │
│ User data found:                              │
│   ☑ Users/james/Documents      12.3 GB       │
│   ☑ Users/james/Pictures        8.1 GB       │
│   ☑ Users/james/Downloads       4.2 GB       │
│   ☐ Users/james/AppData        15.7 GB       │
│   ☐ Windows/                   42.1 GB       │
│                                               │
│ [Select what to migrate]  [Start Migration]   │
└──────────────────────────────────────────────┘
```

fisherman already has **Slurp** — a Windows data extraction subsystem
that reads NTFS user directories before partitioning. The migration tool
exposes this to the user as a selection UI.

#### Phase 2: Data extraction

User selects categories. fisherman's Slurp extracts them from NTFS to a
staging area in RAM (/run/fisherman-slurp).

#### Phase 3: Repartition and install

1. Shrink the NTFS partition (or confirm full wipe)
2. Run fisherman with a recipe that:
   - Targets the real disk (not a loop device)
   - Uses `slurp` field to inject extracted data post-install
3. User data lands in `/home/` on the new native install
4. Old NTFS can be kept as a data partition or wiped

### 4.3 End state options

| Option | Layout |
|---|---|
| Full Linux, keep data | ESP + /boot + / (xfs) + /data (NTFS, old files) |
| Full Linux, clean | ESP + /boot + / (xfs) + /home (xfs) |
| Keep dual-boot, native Linux | ESP + Windows (NTFS, shrunk) + /boot + / (xfs) |

---

## 5. Uninstall

wootc is fully reversible:

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

Implementation: `wubi.exe` already has an uninstall mode that removes BCD
entries and deletes the installation directory. wootc extends this to also
clean ESP entries.

---

## 6. Key Dependencies

| Project | Role | License |
|---|---|---|
| [WubiUEFI](https://github.com/hakuna-m/wubiuefi) | Windows installer, BCD, GRUB core images | GPL-2.0 |
| [fisherman](https://github.com/projectbluefin/fisherman) | Disk partitioning, bootc install, data slurp | Apache-2.0 |
| [bootc](https://github.com/containers/bootc) | Container-native OS install and updates | Apache-2.0 |
| [bootupd](https://github.com/coreos/bootupd) | Bootloader installation (invoked by bootc) | Apache-2.0 |
| [podman](https://github.com/containers/podman) | OCI image pull and container execution | Apache-2.0 |
| [skopeo](https://github.com/containers/skopeo) | Image inspection, OCI layout export | Apache-2.0 |

---

## 7. Project Structure

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

## 8. Open Questions

1. **Secure Boot with GRUB2**: WubiUEFI uses shim for Secure Boot. wootc
   inherits this for the GRUB2 path. systemd-boot has native Secure Boot
   support via signed UKIs. Signing pipeline and key management TBD.

2. **ARM64 Windows**: WubiUEFI supports x86_64 only. ARM64 Windows devices
   (Surface Pro X, etc.) use a completely different boot chain. Deferred.

3. **ntfs3 force mount safety**: The `force` flag in the mount hook handles
   dirty NTFS volumes (Fast Startup), but writes to a dirty NTFS partition
   carry theoretical corruption risk. In practice, ntfs3's `force` mode
   has been stable since Linux 6.1. Should still be tested extensively.

4. **systemd-boot kernel sync hook**: The `bootc post-transaction` hook
   that copies kernels from inside root.disk to the ESP needs to handle
   the case where root.disk is not yet mounted at hook execution time.
   May need to be a systemd path unit instead.

---

## 9. Build & Test

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/tuna-os/wootc.git
cd wootc

# Build deployer initramfs
cd deployer
podman build -t wootc-deployer .
podman run --rm -v $(pwd)/out:/out wootc-deployer
# → out/vmlinuz, out/initramfs.img

# Test with QEMU (requires an NTFS partition image with C:\wootc\ structure)
# TBD: test harness using qemu + Windows PE + wootc files
```
