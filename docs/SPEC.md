# wootc — Windows bootc Installer (Specification)

wootc installs bootc-based Linux images from Windows without
repartitioning. The OS lives in a file (`root.disk`) on the Windows NTFS
partition. Uninstalling is deleting one file and one BCD entry.

**Prior art**: [WubiUEFI](https://github.com/hakuna-m/wubiuefi) proved the
dual-boot loop-file model with millions of users. wootc replaces Wubi's
Ubuntu-specific pipeline (ISO → casper → ubiquity → preseed) with
[fisherman](https://github.com/tuna-os/fisherman) driving
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
by an OSTree transaction hook installed during deployment.

The hook (`/etc/ostree/hooks.d/99-wootc-esp-sync`) runs after every
successful `bootc update`:

1. Detect the ESP and mount it if not already at `/boot/efi`
2. Read the active BLS entries from the new deployment
3. Hard-copy the new kernel + initrd to `ESP:/EFI/wootc/active/`
4. Move the previous deployment to `ESP:/EFI/wootc/backup/`
   (so system rollback works if the new image fails to boot)
5. Clean up old, unreferenced kernels to prevent filling the
   typically small (~100MB) Windows ESP

FAT32 doesn't support symlinks, so hard copies are necessary.
OSTree deployments change the kernel path with every upgrade
(e.g. `/boot/ostree/yellowfin-<hash>/vmlinuz`), so the hook
reads BLS entries to find the correct source paths.

For reliability, the installer configures `/etc/fstab` to mount the
physical ESP by UUID with `x-systemd.automount` — ensuring the hook
can reliably access the ESP on-demand during `bootc update`, even if
it was unmounted or locked by firmware.

The tradeoff: simpler bootloader (no GRUB complexity), native UKI
and Secure Boot support, but requires the sync hook and consumes
~100-200MB of ESP space per deployment.

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

    HOST_MNT="/run/initramfs/wootc-host"
    mkdir -p "$HOST_MNT"

    # Mount the host NTFS partition read-write.
    # If Windows was not shut down cleanly, ntfs3 will refuse rw mount.
    # Rather than forcing (which risks corruption), we tell the user to
    # boot Windows once and perform a full shutdown.
    if ! mount -t ntfs3 -o rw,nobarrier,async,prealloc "$HOST_DEV" "$HOST_MNT"; then
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

#### The Remount Trap — Solved with initramfs-hosted Mount

Standard Linux init scripts attempt a generic root remount
(`mount -o remount,rw /`) late in the boot sequence. Because the real
root is nested inside a loop device backed by a host mount, a standard
remount command cannot reach through both layers and will fail.

**The bigger problem: systemd shutdown dependency cycle.**
If `/host` is a systemd-managed mount, shutdown will try to unmount it.
But `/host` can't be unmounted because `/` (the loop device) holds an
open file descriptor on `/host/wootc/disks/root.disk`. Systemd waits 90
seconds, force-kills services, and leaves NTFS dirty — causing a boot
loop on next start (ntfs3 refuses rw mount on dirty volume).

**Fix:** Mount the NTFS host to `/run/initramfs/wootc-host` inside the
dracut hook — `/run` is a tmpfs, not managed by local-fs unmount targets.
After pivot-root, a systemd service bind-mounts the host directory to
`/host` for user convenience:

```ini
# /etc/systemd/system/wootc-host-bind.service
[Unit]
Description=Bind wootc host mount to /host
DefaultDependencies=no
Before=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mount --bind /run/initramfs/wootc-host /host
ExecStop=/usr/bin/umount /host

[Install]
WantedBy=local-fs.target
```

No fstab entry needed for the loop root — dracut handles mounting it
to `$NEWROOT` during the mount phase. The bind-mount to `/host` is a
convenience, not a boot requirement.

The bind is reversed on shutdown (`ExecStop`) before systemd attempts
to unmount anything — breaking the dependency cycle cleanly.

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
| [fisherman](https://github.com/tuna-os/fisherman) | Go binary: partition, format, bootc install to-filesystem |
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
     wootc.luks=none|tpm2-luks|luks-passphrase       (optional)
     wootc.luks-passphrase=...                        (optional)
     wootc.vault=/wootc/install/vault.json          (optional, secure credentials)
5. Find NTFS partition containing /wootc/disks/root.disk
6. Mount NTFS read-write at /mnt/ntfs (in-kernel ntfs3 driver, Linux 5.15+)
7. If wootc.vault= is set: ingest vault.json, shred it from NTFS
8. losetup -fP /mnt/ntfs/wootc/disks/root.disk
9. Write fisherman recipe JSON → /tmp/recipe.json
10. Run: fisherman /tmp/recipe.json
11. If /wootc/install/apps.json lists Flatpaks: install them into the
    target (§4.3)
12. losetup -d, umount
13. reboot
```

### 2.3 Secure Credential Handoff (vault.json)

Passing user credentials from Windows to the non-interactive Linux
deployer requires care: plain-text passwords must never appear in
`/proc/cmdline` (readable by unprivileged processes and captured in
logs) or persist on the unencrypted NTFS partition after deployment.

wootc uses a **transient host-file payload with client-side hashing**:

```
┌────────────────────────────────────────────────────────┐
│ WINDOWS (wootc.exe)                                    │
│ 1. Hash password → $y$ yescrypt / $6$ SHA-512         │
│ 2. Write C:\wootc\install\vault.json (ACL-restricted)  │
└───────────────────────────┬────────────────────────────┘
                            │ Reboot
                            ▼
┌────────────────────────────────────────────────────────┐
│ DEPLOYER INITRAMFS                                     │
│ 3. Mount NTFS, read vault.json                         │
│ 4. Merge credentials into fisherman recipe             │
│ 5. shred -u vault.json                                 │
└───────────────────────────┬────────────────────────────┘
                            │ fisherman runs
                            ▼
┌────────────────────────────────────────────────────────┐
│ TARGET SYSTEM                                          │
│ 6. User account, hostname, timezone injected           │
└────────────────────────────────────────────────────────┘
```

#### Windows Side: Hash Before Storage

wootc.exe does not store or forward raw passwords. It uses a bundled
native `libcrypt` implementation to hash credentials before they leave
the process:

- **Yescrypt (`$y$`)** for Fedora/RHEL derivatives
- **SHA-512 (`$6$`)** for Enterprise Linux compatibility
- A random crypt-compliant salt is generated per installation

**vault.json** is written to `C:\wootc\install\vault.json` with
Windows ACLs restricting read access to `SYSTEM` and `Administrators`:

```json
{
  "hostname": "tunaos",
  "username": "liveuser",
  "full_name": "Zoë O'Brien-Åberg",
  "password_hash": "$y$j9T$RlhOWV...$v9zZ291aEF...",
  "timezone": "America/New_York",
  "locale": "en_US.UTF-8"
}
```

#### Bootloader Link

A **single reference** is passed via the kernel cmdline — no credentials
ever appear in the bootloader config or `/proc/cmdline`:

```
wootc.vault=/wootc/install/vault.json
```

#### Deployer Side: Ingest, Merge, Shred

The deployer initramfs handles the vault in three steps:

1. **Mount NTFS** — the host partition is already mounted at
   `/run/initramfs/wootc-host`.
2. **Locate vault** — reads `wootc.vault` from `/proc/cmdline`,
   confirms the file exists, parses JSON into in-memory variables.
3. **Merge into recipe** — injects credentials into the fisherman
   recipe's `user` field:

```json
{
  "disk": "/dev/loop0",
  "image": "ghcr.io/tuna-os/yellowfin:gnome",
  "hostname": "tunaos",
  "user": {
    "username": "liveuser",
    "fullname": "Zoë O'Brien-Åberg",
    "password": "$y$j9T$RlhOWV...",
    "groups": ["wheel", "video", "audio"]
  }
}
```

#### Self-Destruct

Before fisherman begins deployment, the vault file is securely erased:

```bash
shred -u /run/initramfs/wootc-host/wootc/install/vault.json
```

This runs **before** a single OCI layer is extracted. Even if the
machine loses power mid-installation, no authentication metadata
persists on the unencrypted NTFS partition.

#### Target Provisioning

fisherman's post-install hooks write the hashed password into
`/target/etc/shadow`, the username into `/target/etc/passwd`, and the
hostname into `/target/etc/hostname`.

The account's full name comes from Windows on every install, whether or
not Windows-Style Mode is on. The installer reads the full name of the
account that it moves. For a local account, it reads the local account
database (`NetUserGetInfo` level 10, `usri10_full_name`). For a domain or
Microsoft account, and for a local account with no name there, it uses
`GetUserNameEx(NameDisplay)`. It writes it to the vault as
`full_name`, an empty string when Windows has none.

The deployer puts the name in
the recipe as `user.fullname`, and fisherman gives it to
`useradd --comment`, so it becomes the GECOS full name (`getent passwd`
field 5). useradd refuses a `:` or a newline in that field, and fisherman
then stops the whole install. So the installer and the deployer both apply
one rule to the name:

- Every Unicode whitespace character becomes a space.
- The rule removes control characters (Unicode Cc), invalid UTF-8, `:` and
  `,`. A comma starts the next subfield of GECOS.
- Runs of spaces become one space. The rule removes the spaces at the start
  and at the end.
- The rule cuts the name to 256 bytes, on a character boundary.

The rule keeps every other character, in any script, byte for byte. This includes
apostrophes, hyphens, periods, quotes and backslashes; jq builds the
recipe, so quotes and backslashes cannot break it. The deployer logs
`account full name from Windows: <name>`, or `account full name from
Windows: none recorded`. When `wootc-identity apply` copies the Windows
account picture at boot, it also writes this name as AccountsService
`RealName`. It runs `chfn` only when Windows-Style Mode collected a
different `fullName` into `slurp.json`, so it never clears this name.
Phase 3 (`wootc-go-native`) takes the first comma subfield of the Phase-2
account's GECOS field, applies the same rule and copies it to the native
install's account.

The installer also reads the Windows time zone, UI language and keyboard
layout into `\wootc\install\slurp\slurp.json` (`timezone`, `language`,
`keyboardLayout`). The deployer gives them to fisherman as the recipe
fields `timezone`, `locale` and `keyboard`. It changes the BCP-47 language
tag to a glibc locale: `en-US` becomes `en_US.UTF-8`, and a tag without a
region gets the main region of its language (`ja` becomes `ja_JP.UTF-8`).
fisherman writes `/etc/localtime`, `/etc/locale.conf`, `/etc/vconsole.conf`
and the X11 keyboard file in the deployment's `/etc`. The deployer leaves
out a value that fisherman's recipe rules refuse, and logs it, because one
refused value stops the whole install. Without `slurp.json`, the time zone
comes from `clock.json` (below) and the image's other settings stay.

When the user moves to a native disk (Phase 3), `wootc-go-native` gives
fisherman the settings of the Phase-2 system. These are its hostname
(`/etc/hostname`), its time zone (`/etc/localtime`), its `LANG`
(`/etc/locale.conf`) and its keyboard (the `XKB*` keys of
`/etc/vconsole.conf`). It also sets `"copyNetworkProfiles": true`, so
fisherman copies the Phase-2 NetworkManager profiles, which include the
Wi-Fi networks from Windows. It copies the Phase-2 `/etc/adjtime` to the
native install, which keeps Windows next to it.

On first boot, the display manager presents a login prompt. The user
types the same password they chose on Screen 1 — it matches the hash.
No cleartext ever touched disk.

#### Hardware clock

Windows keeps the hardware clock (RTC) in local time unless
`RealTimeIsUniversal` is set, and Linux reads the RTC as UTC by default. In
the "Saving your settings" step the engine writes
`<storage drive>:\wootc\install\clock.json` on every install:

```json
{"schemaVersion":1,"rtcLocal":true,"utcOffsetSeconds":32400,"timezone":"Asia/Tokyo"}
```

`utcOffsetSeconds` is the Windows offset from UTC when the install ran,
daylight saving included. `timezone` is the IANA name of the Windows zone,
or empty when wootc has no mapping for it. When `rtcLocal` is true:

- Before it writes any timestamp, the deployer subtracts the offset from
  its system clock, once per boot. On a PC set to Tokyo time, deployer
  timestamps were 9 hours in the future without this (probe 44869134695).
- When `timezone` is set, the deployer writes `/etc/adjtime` with `LOCAL`
  in the deployment. When `slurp.json` has no time zone, the recipe uses
  this zone. The installed system then reads and writes the RTC in local
  time, as Windows does. Otherwise Linux runs hours off until NTP corrects
  it. Then Linux writes UTC to the RTC, and Windows is hours off.

With no `clock.json`, `rtcLocal` false or an empty `timezone`, the clock
stays as the kernel reads it and the RTC stays in UTC.

### 2.4 Filesystem Selection

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

### 2.5 Fisherman Recipe

Generated at deploy time from kernel cmdline args (and vault.json if provided):

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
  "flatpaks": [],
  "user": {
    "username": "liveuser",
    "fullname": "Zoë O'Brien-Åberg",
    "password": "$y$j9T$RlhOWV...",
    "groups": ["wheel", "video", "audio"]
  },
  "slurpWallpapers": true
}
```

The `image` field is the OCI reference for the target OS. fisherman
handles:
- **CheckImage**: compares remote vs local digest, determines if pull needed
- **Pull**: `podman pull` to containers-storage
- **Install**: `podman run --privileged <image> bootc install to-filesystem /target`
- **Post**: flatpak copy, hostname write, Plymouth args, LUKS args, Bluetooth/WiFi sync, audio config, cache warm, fstrim/remount-ro/fsfreeze finalize

The `flatpaks` list does not download apps. A non-empty list makes
fisherman copy the host's whole `/var/lib/flatpak`, and `[]` copies
nothing. The deployer initramfs has no Flatpaks, so the deployer sets
`[]` and installs the selected apps itself (§4.3).

### 2.6 LUKS Encryption

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

### 2.7 Post-deployment: loop-root dracut module

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
| **BitLocker (auto)** | BitLocker-protected C: | Auto-created D: partition | Good — one click, C: stays protected |
| **BitLocker (manual)** | BitLocker-protected C: | User-selected unencrypted partition | OK — user picks an existing drive |
| **Native** | Any | Native Linux partition (post-migration) | Best — no NTFS dependency |

> **Why "Suspend BitLocker" alone doesn't work**: BitLocker suspension
> writes the VMK to volume metadata so Windows can boot without TPM,
> but the sectors remain encrypted. Linux's `ntfs3` driver cannot
> decrypt BitLocker volumes — it sees raw ciphertext. The deployer
> would fail to find `/wootc/disks/root.disk` on an encrypted volume
> regardless of suspension state.
>
> The only viable BitLocker paths are: (a) use an unencrypted data
> partition for root.disk, or (b) fully decrypt C: before installing.

**Normal mode detection** — the installer queries volume status:

```cmd
manage-bde -status C:
```

| BitLocker status | Action |
|---|---|
| Fully Decrypted | Proceed in Normal mode. |
| Protection On | Offer auto-create D: or manual partition selection. |
| Encryption In Progress | Hard block. "Windows is encrypting C:. Wait for completion." |

> **Why no "suspend and continue" option**: BitLocker suspension allows
> Windows to boot without TPM by writing the VMK to volume metadata, but
> the NTFS sectors remain encrypted on disk. Linux's `ntfs3` driver has
> no BitLocker decryption capability — it would see raw ciphertext and
> fail to find root.disk. The only viable path is storing root.disk on
> an unencrypted partition.

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

**Auto-create implementation** — the installer suspends BitLocker
(if active), shrinks C:, creates D:, then resumes protection:

```powershell
# 1. Check and suspend BitLocker if active
$bitlocker = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
if ($bitlocker -and $bitlocker.ProtectionStatus -eq "On") {
    Suspend-BitLocker -MountPoint "C:" -RebootCount 1
    Write-Host "BitLocker suspended for resize"
}

# 2. Query maximum shrink size
$partition = Get-Partition -DriveLetter C
$maxShrink = Get-PartitionSupportedSize -DriveLetter C
$targetSize = 60GB

# 3. Shrink C: and create D:
if ($maxShrink.SizeMax - $maxShrink.SizeMin -gt ($targetSize * 1.1GB)) {
    Resize-Partition -DriveLetter C -Size ($maxShrink.SizeMax - ($targetSize * 1GB))
    $newPart = New-Partition -DiskNumber $partition.DiskNumber `
        -UseMaximumSize -DriveLetter D
    Format-Volume -DriveLetter D -FileSystem NTFS `
        -NewFileSystemLabel "wootc-data" -Confirm:$false
    Write-Host "Created D: ($targetSize GB) for wootc"
}

# 4. Resume BitLocker (or let it auto-resume on reboot)
if ($bitlocker -and $bitlocker.ProtectionStatus -eq "On") {
    Resume-BitLocker -MountPoint "C:"
}
```

**Why this is safe:** `Suspend-BitLocker -RebootCount 1` writes the
encryption key to the volume metadata in the clear — the disk stays
encrypted, but offline tools (and the partition manager) can manipulate
the structure. Protection resumes automatically on the next Windows
boot. No decryption, no re-encryption, no performance impact.

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

When wootc.exe creates `root.disk`, performance depends on cluster
allocation. On spinning disks, fragmented sparse files cause significant
I/O overhead through the loop layer.

**Approach: sparse allocation + in-Linux TRIM.**

Rather than using `SetFileValidData` (which exposes raw unzeroed disk
blocks containing previously deleted Windows data — a privacy risk),
wootc creates the file as **sparse** and lets the deployer initramfs
issue a fast discard:

**Windows side** — create sparse file:

```c
HANDLE h = CreateFileW(path, GENERIC_WRITE, 0, NULL,
                        CREATE_NEW,
                        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SPARSE_FILE,
                        NULL);

LARGE_INTEGER size;
size.QuadPart = (LONGLONG)size_gb * 1024 * 1024 * 1024;
SetFilePointerEx(h, size, NULL, FILE_BEGIN);
SetEndOfFile(h);

// Mark as sparse — NTFS allocates on demand
DWORD tmp;
DeviceIoControl(h, FSCTL_SET_SPARSE, NULL, 0, NULL, 0, &tmp, NULL);
CloseHandle(h);
```

**Linux side** — after `losetup`, before `mkfs`:

```bash
# Discard all unused blocks on the loop device.
# On SSDs this is instant (ATA TRIM). On spinning disks
# this causes NTFS to allocate contiguous clusters.
blkdiscard -f "$LOOP_DEV"
```

`blkdiscard` on a loop device backed by a sparse NTFS file causes
NTFS to allocate the blocks. The allocation pattern is contiguous
if the volume has free space — giving near-`SetFileValidData`
performance without the security risk of reading stale Windows data.

**Why this is safe:** `blkdiscard` writes nothing to the file's data
blocks — it only tells the filesystem "these blocks are now in use."
NTFS allocates them from the free space pool. The guest sees
discarded (zeroed) blocks because the loop device honors the discard
by returning zeros for unmapped regions.

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

### 3.7 GUI Flow

The Windows installer (`wootc.exe`) has four screens:

#### Screen 1: Launchpad (Initial Configuration)

```
+-------------------------------------------------------------------------+
|  🐠 wootc — Windows bootc Installer                                  _ 🗙 |
+-------------------------------------------------------------------------+
|                                                                         |
|  Select a Linux Distribution Variant:                                   |
|  [ 🐠 Yellowfin GNOME (AlmaLinux Kitten 10)                        | 🠟 ] |
|    Modern GNOME desktop on Enterprise Linux. Reliable and stable.       |
|                                                                         |
|  Virtual Disk Size:                                                     |
|  [======================o---------------------] 40 GB                  |
|  (Minimum: 20 GB. Available unallocated or disk space: 240 GB)          |
|                                                                         |
|  Linux User Credentials:                                                |
|  Username: [ James               ] Target Hostname: [ tunaos          ] |
|  Password: [ ****************   ] Confirm:         [ **************** ] |
|                                                                         |
|  +-------------------------------------------------------------------+  |
|  | Options: [x] Pre-allocate contiguous disk clusters (Recommended)  |  |
|  |          [ ] Enable systemd-boot path instead of default GRUB2    |  |
|  +-------------------------------------------------------------------+  |
|                                                                         |
|                        [ Try in VM ]    [ Install ]    [ Cancel ]       |
+-------------------------------------------------------------------------+
```

**Button actions:**
- **[Try in VM]**: Required VM-first direction; current builds remain capability-gated until ADR 0004 passes.
  Bypasses BCD modification. Launches a background Alpine builder VM to pull
  the OCI image into a local virtual disk and starts QEMU immediately (§6.1).
  No reboot. In standard 1.0 builds, this affordance is hidden in favor of
  post-install Phase 1 VM Boot (ADR 0001, #231).
- **[Install]**: Validates fields, proceeds to pre-flight checks.

#### Screen 1.5: Pre-Flight Mitigation (Conditional)

Before writing any data, the installer runs background system checks.
If a hazard is found, a modal interrupts the flow:

**Case A: BitLocker Detected on C:**

```
+-------------------------------------------------------------------------+
| ⚠ BitLocker Drive Encryption Active                                     |
+-------------------------------------------------------------------------+
| wootc cannot read an encrypted NTFS volume from Linux.                   |
| The root.disk file must live on an unencrypted partition.                |
|                                                                         |
|  (•) Automatically Create an Unencrypted Data Partition                 |
|      Shrink C: non-destructively by 60 GB to generate a new D:\ drive   |
|      dedicated to wootc. Your C: drive remains protected by BitLocker.  |
|                                                                         |
|  ( ) Install to an alternative unencrypted data partition               |
|      Target Drive: [ E:\ (Backup Drive - 180 GB Free)               | 🠟 ] |
|                                                                         |
|                        [ Proceed ]    [ Abort Installation ]            |
+-------------------------------------------------------------------------+
```

**Case B: Fast Startup Warning**

```
+-------------------------------------------------------------------------+
| ⚙ Fast Startup Deactivation Required                                    |
+-------------------------------------------------------------------------+
| Windows Fast Startup prevents clean partition unmounting on shutdown,    |
| which will cause the Linux deployment engine to fail.                  |
|                                                                         |
| [x] Automatically disable Windows Fast Startup via Registry injection   |
|     (Highly recommended. Non-destructive).                              |
|                                                                         |
|                        [ Continue ]    [ Abort Installation ]           |
+-------------------------------------------------------------------------+
```

#### Screen 2: Deployment Progress

Once pre-flight checks pass, the installer transitions to an active
progress view:

```
+-------------------------------------------------------------------------+
|  🐠 wootc — Running Installation Pipeline                             _ 🗙 |
+-------------------------------------------------------------------------+
|                                                                         |
|  Step 1: Allocating Virtual Storage File...                             |
|  [======================================================] 100% (Done)   |
|                                                                         |
|  Step 2: Downloading Deployer Kernel and Initrd Components...           |
|  [==========================>---------------------------] 52% (4.2 MB/s) |
|                                                                         |
|  Step 3: Building EFI System Partition Structures & BCD Entries...      |
|  [------------------------------------------------------] 0%            |
|                                                                         |
|  Current Status: Fetching 'deployer-initramfs.img' from GitHub CDN...   |
|                                                                         |
|                                                         [ Cancel ]      |
+-------------------------------------------------------------------------+
```

On completion, a dialog appears:

```
┌─────────────────────────────────────────────┐
│ ✅ Installation Success!                     │
│                                              │
│ Your system layout is primed. A new boot     │
│ menu option marked "wootc" has been added    │
│ to the Windows Boot Manager.                 │
│                                              │
│        [ Reboot Now ]   [ Close ]            │
└─────────────────────────────────────────────┘
```

#### Screen 3: Maintenance Control Panel (Subsequent Launches)

When wootc.exe detects an existing `root.disk` installation:

```
+-------------------------------------------------------------------------+
|  🐠 wootc — System Management Panel                                   _ 🗙 |
+-------------------------------------------------------------------------+
|                                                                         |
|  Detected Installation: TunaOS (Yellowfin GNOME)                       |
|  Location: C:\wootc\disks\root.disk                                     |
|  Allocated Capacity: 40 GB                                              |
|                                                                         |
|  +-------------------------------------------------------------------+  |
|  |  🚀 Boot Linux Directly Inside Windows (Virtual Machine Mode)      |  |
|  |  Launches your actual Linux system inside a QEMU hardware-        |  |
|  |  accelerated window using the Windows Hypervisor Platform.        |  |
|  |  [ Launch VM ]                                                     |  |
|  +-------------------------------------------------------------------+  |
|                                                                         |
|  +-------------------------------------------------------------------+  |
|  |  🧹 Safe System Uninstallation                                    |  |
|  |  Completely purges the Linux runtime, clears out wootc BCD entries,|  |
|  |  reclaims the host storage space, and cleans the ESP.             |  |
|  |  [ Uninstall wootc ]                                               |  |
|  +-------------------------------------------------------------------+  |
|                                                                         |
|                                                         [ Close ]       |
+-------------------------------------------------------------------------+
```

#### Screen 4: Uninstall Wizard

Adapts based on whether the system used Normal mode (C:) or BitLocker
mode (dedicated D: partition):

```
+-------------------------------------------------------------------------+
|  🧹 wootc System Uninstallation Wizard                                 _ 🗙 |
+-------------------------------------------------------------------------+
|                                                                         |
|  This process will permanently delete all data stored inside your       |
|  Linux root.disk container file.                                        |
|                                                                         |
|  The uninstaller will execute the following sequences:                  |
|  ✔ Remove the 'wootc' selection item from Windows Boot Manager          |
|  ✔ Erase the parent payload target file structure located at C:\wootc\  |
|  ✔ Clean up wootc files from the EFI System Partition (ESP)            |
|                                                                         |
|  [Conditional — displayed only if separate D: partition exists]         |
|  [x] Automatically delete partition D: (wootc-data) and extend C:       |
|                                                                         |
|  ⚠ Ensure all files inside the Linux sandbox are backed up!             |
|                                                                         |
|                        [ Confirm Uninstallation ]     [ Abort ]         |
+-------------------------------------------------------------------------+
```

#### Navigation Topology

| Initial State | User Action | UI Transition | Execution |
|---|---|---|---|
| Fresh Host | Launch wootc.exe | → Screen 1 (Launchpad) | Parameter validation |
| Fresh Host | Click "Install" with BitLocker active | → Screen 1.5 (Case A) | Auto-create D: or manual partition selection |
| Fresh Host | All checks green | → Screen 2 (Progress) | BCD alteration + reboot |
| Deployed Host | Launch wootc.exe | → Screen 3 (Control Panel) | Route splitting |
| Deployed Host | Click "Launch VM" | → Minimize to tray | QEMU via WHPX on root.disk |
| Deployed Host | Click "Uninstall wootc" | → Screen 4 (Uninstaller) | Disk geometry reversion + BCD purge |

wootc's defining feature is **transparent passthrough**: instead of
immediately copying everything, the installed system uses Windows
resources directly. Documents, Pictures, Downloads, Steam libraries,
and browser profiles are accessible from day one via bind mounts into
the Linux home directory. No long initial copy. No "where are my files?"

Weeks or months later, the user can choose to convert to native Linux
storage — one category at a time, at their own pace.

### 4.1 Transparent Passthrough (Day One)

On first boot into the installed system, the `99wootc-boot` dracut module
mounts the Windows NTFS partition at `/run/initramfs/wootc-host`. A systemd service
(`wootc-passthrough.service`) then creates bind mounts. It explicitly
depends on `wootc-host-bind.service` and tears down before it on
shutdown:

```ini
# /etc/systemd/system/wootc-passthrough.service
[Unit]
Description=Bind Windows User Profiles to Home
DefaultDependencies=no
After=wootc-host-bind.service
Requires=wootc-host-bind.service
Before=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/wootc-mount-user-dirs
ExecStop=/usr/local/bin/wootc-umount-user-dirs

[Install]
WantedBy=local-fs.target
```

This ordering ensures that on shutdown, the user directory bind mounts
are torn down (`ExecStop`) **before** `wootc-host-bind.service` unmounts
`/host` — avoiding a "target is busy" failure from nested bind mounts.

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
(via the rw NTFS mount). While Linux runs, wootc removes the Windows
read-only attribute from bridged folders and sets it again at shutdown. See
[Linux access to the Windows volume](ntfs-on-linux.md#linux-access-to-the-windows-volume).

**Steam libraries** are detected and reused in-place, without a
re-download:

```
/host/Program Files (x86)/Steam/steamapps/  →  found by the Steam bridge
```

Linux Steam writes its own `libraryfolders.vdf` at its first start. The
bridge never changes that file. Thus the bridge records the path of each
Windows library. The migration chooser tells the user to add each library
one time in Steam **Settings > Storage > Add Library**. After that step, the
games run in place, with Proton for compatibility. Games do not appear
without that step.

**Browser profiles:** the first Phase-2 boot copies them. The copy does not
change Linux browser data. The user can turn off the category or one browser
in the migration chooser. If the copy fails, the next boot tries again.
Each browser gets its own Linux profile. The profile goes where the browser
looks: its existing profile, else the installed Flatpak, else the installed
native browser, else the Flathub Flatpak location.

| Windows browser | Linux equivalent | What migrates |
|---|---|---|
| Chrome | Chrome (Flatpak or native) | bookmarks, history; passwords only through the separate, consented session migration |
| Edge | Edge for Linux (Flatpak or native) | bookmarks, history |
| Firefox | Firefox (Flatpak or native) | bookmarks, history, passwords, extensions |

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
| 3. Import browser profile | Copy bookmarks/history (Firefox: whole profile) at first boot | Yes (delete imported profile) |
| 4. Convert Documents to native | Copy files, update bind mount | Yes (files still on NTFS until stage 6) |
| 5. Convert home to native | Move `$HOME` to native Linux filesystem | Yes (snapshot rollback) |
| 6. Remove Windows | Delete Windows partition, expand Linux | **No** (Windows is gone) |

### 4.3 App Detection

The Windows engine finds installed apps before the install starts. It reads
the `DisplayName` of each entry in the three Uninstall registry keys:
HKLM, HKLM `WOW6432Node`, and HKCU of the person who runs the installer.
One table, [`app/data/app-flatpaks.json`](../app/data/app-flatpaks.json),
maps a name to a Flathub app. Each entry has a `key`, the Linux app `name`,
its `flatpak` ID, and `match`: lowercase parts of a `DisplayName`. The first
entry that matches a name wins. The engine embeds this table. The deployer
and `wootc-detect-apps` read the same file.

Some examples:

| Windows `DisplayName` | Flatpak |
|---|---|
| `GIMP 2.10.36` | `org.gimp.GIMP` |
| `Inkscape 1.4.2` | `org.inkscape.Inkscape` |
| `Audacity 3.7.1` | `org.audacityteam.Audacity` |
| `Microsoft Visual Studio Code` | `com.visualstudio.code` |
| `Steam` | `com.valvesoftware.Steam` |

The table has no entry for Microsoft Edge, because each Windows 11 PC has it.

The install form shows an **Apps** section with one checkbox for each
detected Flatpak. All boxes start checked. The form shows this text:

> We'll install the Linux versions of these apps from Flathub; uncheck any you don't want.

When the engine detects no app, the form does not show the section. The
plan sends the checked IDs in `InstallConfig.flatpaks`. The engine refuses
an ID that it did not detect on this PC. It also refuses an ID that occurs
two times, and a list of more than 64 IDs. The headless CLI has the same
check for `-flatpaks=id1,id2`.

In the "Saving your settings" step, the engine writes
`<storage drive>:\wootc\install\apps.json` beside the vault. It writes this
file for each install, with an empty list when the person keeps no app:

```json
{"schemaVersion":1,"remote":"flathub","remoteUrl":"https://dl.flathub.org/repo/flathub.flatpakrepo","flatpaks":["org.audacityteam.Audacity","org.inkscape.Inkscape"]}
```

After fisherman, the deployer installs each listed app into the target's
system Flatpak installation (`payload/deployer/flatpak-install.sh`). It
runs the `flatpak` of the installed image in a container, with the
target's `/var/lib/flatpak` mounted. The deployer:

- Installs only IDs that are in `app-flatpaks.json`.
- Adds the remote from `remoteUrl` if the image does not have it.
- Tries each app up to three times. An app that fails does not stop the
  other apps or the install.
- Counts an app as installed only when `flatpak info --system <id>` finds
  it in the target after the install.
- Applies the image's SELinux file contexts to the installed files. If
  SELinux enforces its policy on the target, an app without labels counts
  as failed.

The deployer writes the requested IDs to `/etc/wootc/flatpaks.list`. It
writes this receipt to `/etc/wootc/flatpak-install.json` in the target and
to `\wootc\install\flatpak-install.json` on Windows:

```json
{"schemaVersion":1,"requested":["…"],"installed":["…"],
 "failed":[{"id":"…","error":"…"}]}
```

Each app also gives one serial line: `wootc: flatpak installed: <id>` or
`wootc: flatpak FAILED: <id>: <reason>`.

On Linux, `wootc-detect-apps` uses the same map for the dashboard. Its
`bridge-apps.json` gives each app an `installed` value, which is true only
when `flatpak info --system <id>` finds the app on the Linux system.

When the user moves to a native disk (Phase 3), `wootc-go-native` gives
fisherman the apps of the Phase-2 system's Flatpak installation. Thus
fisherman copies that installation, with its runtimes, to the native disk.
After the install, `wootc-go-native` logs each app as
`wootc: native flatpak present: <id>` or
`wootc: native flatpak MISSING: <id>`.

### 4.4 Windows-Style Mode

On first login, the system adopts the Windows host's aesthetics to reduce
the visual shock of switching OS. The install form has a checkbox for this
mode. The Wails launchpad sets it by default, under Advanced. The native
shell uses the engine default, which is off:

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

### 4.6 Device and Connectivity Migration

wootc should make the Linux desktop feel familiar without silently copying
credentials or opaque Windows state. Migration actions therefore fall into
three consent tiers:

| Tier | Policy | Examples |
|---|---|---|
| Apply automatically | Non-secret preferences with an obvious Linux equivalent, plus the connectivity a user cannot comfortably be without | timezone, keyboard layout, language, accessibility settings, wallpaper, accent color, hostname, browser homepage, personal Wi-Fi networks (open/WPA-PSK/WPA3-SAE), network printers (driverless IPP queues) |
| Offer with preview | Useful data or configuration whose effect the user can inspect | browser data, Steam libraries, VPN endpoints, cloud-folder setup, developer tools, display/audio preferences |
| Never migrate silently | Secrets, identity material, executable automation, or controller-specific state | passwords, private keys, access tokens, certificates, Bluetooth pairing keys, enterprise Wi-Fi credentials, scheduled-task commands |

The maintenance control panel includes a **Bring your setup over** dashboard.
Each item states what will be imported, whether it contains sensitive data,
what remains on Windows, and how to undo the Linux-side result.

#### Wi-Fi profiles

Wi-Fi is a first-class migration feature, on by default: being online on
first boot without re-typing a single network password is the friendliest
thing a migration can do, and macOS-grade setup would never make it a
question. During Windows setup, wootc exports saved profiles using `netsh
wlan export profile
... key=clear`; this requires administrator privileges and exposes the
network key in the exported profile. The transient export is handed to the
first Linux boot, converted to NetworkManager connections, and securely
removed immediately after import.

Automatic import is limited to open networks and personal WPA-PSK/WPA3-SAE
networks. Enterprise 802.1X/PEAP/EAP-TLS networks, captive portals,
device-managed profiles, certificates, and user credentials are detected but
not copied. The dashboard explains what was found and asks the user to finish
authentication in Linux.

#### Printers

wootc moves printers as connections, never as drivers. A Windows driver
cannot run on Linux. CUPS builds an IPP Everywhere queue from the data that the
printer itself reports.

The installer records every printer in the `Collecting your look and Wi-Fi`
step. It uses `Get-Printer`, `Get-PrinterPort` and the default from
`Win32_Printer`. It writes `<storage root>\wootc\install\printers.json`:

```json
{"schemaVersion": 1, "printers": [{"name": "Office Laser", "portName": "IP_10.0.0.9",
  "driverName": "…", "default": true, "shared": false, "portKind": "tcpip",
  "host": "10.0.0.9", "port": 9100, "protocol": "raw"}]}
```

The port sets `portKind`, not the driver. The kinds are `tcpip`, `ipp`,
`wsd`, `usb`, `lpt`, `com`, `file`, `virtual` and `other`. A `tcpip` printer
has a Standard TCP/IP port and records `host`, `port`, `protocol` (raw or lpr)
and `lprQueue`. An `ipp` printer has an http, https, ipp or ipps URL as its
port name, and `uri` keeps it. `file` is `FILE:` or `nul:`. `virtual` is
`PORTPROMPT:` or an XPS, OneNote, fax or PDF port.

On every Phase-2 boot, `wootc-printer-import.service` reads that file from the
Windows volume. The unit runs as root after `cups.service`,
`network-online.target` and `wootc-host-bind.service`. It writes the result to
`/var/lib/wootc/printers.json` with mode 0644:

```json
{"schemaVersion": 1, "printers": [{"name": "Office Laser", "queue": "Office_Laser",
  "status": "added", "uri": "ipp://10.0.0.9:631/ipp/print", "default": true,
  "lastTried": "2026-11-21T04:10:29Z"}]}
```

A `waiting` or `not-migrated` record also has a `reason`. The journal gets one
line for each printer: `wootc-printer-import: <name>: added <uri>`,
`… waiting: <reason>` or `… not migrated: <reason>`.

- A `tcpip` printer gets `ipp://<host>:631/ipp/print`.
- An `ipp` printer keeps its URL. The importer changes http to ipp and https
  to ipps, and adds an implied port 80 or 443.
- The importer first makes sure that the address answers on its IPP port.
  Then it runs `lpadmin -p <queue> -E -v <uri> -m everywhere` with a 90 s
  limit.
- The queue name starts as the Windows name. Each run of characters outside
  `[A-Za-z0-9_-]` becomes one `_`. The importer removes a leading or trailing
  `_` and keeps at most 127 characters. An empty result becomes `printer`. A
  name that is already in the list gets `-2`, `-3` and so on. The comparison
  ignores case.
- If `lpadmin` succeeds, the status is `added`. The Windows default becomes
  the CUPS default if CUPS has no default.
- If `lpadmin` fails or the address does not answer, the status is `waiting`
  and the reason tells why. The importer tries again at the next boot.
- The importer never changes a queue that it added before, also when the user
  removed or changed it. It also does not change a queue that has the same
  name: that printer is `not-migrated`.
- All other printers are `not-migrated` with a reason:
  - Cable printers (usb, lpt, com): `connected by cable to this PC: plug it
    in, and a driverless USB printer is set up automatically; others need
    their Linux driver`
  - WSD printers: `found by Windows on the network (WSD); if it supports
    driverless printing, Settings → Printers lists it`
  - Virtual and file printers: `Windows-only virtual printer`

The migration chooser shows every printer and its status under **Printers**.
If the user turns the category or a printer off, the importer adds no new
queue. It removes no queue. Phase 3 copies the queues that wootc added to the
native disk: their `printers.conf` entries and PPDs, and the report. The native
system does not mount Windows, so a `waiting` printer stays `waiting` there.
wootc does not migrate scanners.

#### Bluetooth devices

wootc may inventory paired Bluetooth devices (friendly name, class, and
address where available) and present a **Reconnect your devices** checklist
for headsets, mice, keyboards, controllers, and BLE accessories. It must not
copy Windows Bluetooth link keys, LE long-term keys, or controller-specific
pairing databases into BlueZ. Those secrets are stack- and controller-specific
and re-pairing is more reliable than attempting an opaque key conversion.

#### Additional migration candidates

The dashboard can offer the following independent, reversible import actions:

| Category | Import behavior |
|---|---|
| Printers/scanners | Network printers become driverless IPP Everywhere queues; cable, WSD and virtual printers are listed with the reason they did not move (see [Printers](#printers)). Windows drivers are never copied. Scanners are not migrated. |
| VPN | Import endpoint, protocol, and non-secret settings; require passwords, certificates, and MFA again. |
| Browser | Import bookmarks by default; offer history, extensions, and password migration only with separate consent. |
| Cloud folders | Detect OneDrive, Dropbox, Google Drive, Syncthing, and Nextcloud; reconnect a Linux client rather than sharing or copying sync databases. |
| Developer setup | Detect VS Code, WSL, Git, containers, language toolchains, and repositories; generate an install/open plan. Copy public SSH keys and Git identity only by consent; never copy private keys or credential stores. **Implemented (Windows-native `%USERPROFILE%\.ssh` and `.gitconfig`):** on every Phase-2 boot `wootc-mount-user-dirs` runs `wootc-developer-bridge <winprofile> <linuxuser>` for each mapped account unless the chooser's **Developer setup** category is off. It copies, byte for byte and owned by the user, `~/.ssh/*.pub` and `known_hosts` (0644), `config` and `authorized_keys` (0600) into `~/.ssh` (0700). It never copies a private key: a file whose first line contains `PRIVATE KEY`, a file with a matching `.pub`, an `id_*` file without an extension, or a PuTTY `.ppk` is listed under `leftOnWindows`. Other `.ssh` files and subdirectories are listed under `notCarried`. From `.gitconfig` it writes `~/.gitconfig` (0644) holding only `user.name`, `user.email`, `user.signingkey` and `init.defaultBranch`, and only when neither `~/.gitconfig` nor `~/.config/git/config` exists. Every other key is listed under `notCarried` by name, never by value: `credential.*`, `core.autocrlf`, `core.sshCommand`, includes, and any identity value that is a Windows drive or UNC path. Existing Linux files are never overwritten: identical files count as `alreadyPresent`, different ones as `preserved`. As root, the wrapper then runs `restorecon -RF` on `~/.ssh` and `~/.gitconfig` when SELinux is enabled. The result is `~/.config/wootc/bridge-developer.json`. Limits: `Include`d SSH config fragments in subdirectories, Git `include` targets, GPG keyrings and Windows credential stores are not carried, and BitLocker-only profile roots are not read. |
| Gaming | Discover Steam libraries, common save locations, and controllers; reuse libraries where compatible and show Proton guidance. |
| Media | Offer portable music/photo library locations and compatible Plex/Jellyfin or OBS configuration exports. |
| Desktop hardware | Offer display layout/scaling, preferred audio device, dock/monitor names, terminal fonts, color schemes, and Windows Terminal profiles as Linux suggestions. |
| Scheduled tasks | Show user-created tasks as a reviewable conversion proposal for systemd timers; never enable a converted command automatically. |

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

## 6. VM Modes: Try Before You Commit

wootc can boot bootc images directly on Windows using QEMU with WHPX
(Windows Hypervisor Platform) acceleration. No reboot. Near-native
performance. Two distinct modes:

### 6.1 Fresh VM from OCI Image (Two-Stage QEMU Handoff)

> **Status, 2026-09-26:** The maintainer requires VM-first as the primary journey.
> [ADR 0004](adr/0004-restore-vm-first-product.md) supersedes the #318 deferral.
> Current releases do not yet provide a proven VM-first path.
> The design below is historical input; disk ownership, readiness, and native promotion
> must meet ADR 0004 before release claims.


"Try before you install" — the user clicks **[Try in VM]** on the
Launchpad, and wootc builds a bootable disk image and launches it in
a QEMU window. No reboot. No BCD modification. If the user likes it,
the same disk image becomes their permanent install.

Because Windows cannot natively handle Linux loopback block allocation,
ext4/btrfs/xfs formatting, or OSTree deployments, wootc uses a
**two-stage handoff**: a headless builder VM does the heavy lifting,
then an interactive QEMU window takes over for the user-facing preview.

#### Stage 1: Headless Builder VM

**1. Workspace Initialization (host)**

wootc.exe creates a temporary workspace at `%TEMP%\wootc-preview\`.
A 20GB sparse disk file `preview.raw` is created using
`CreateFileW` + `FSCTL_SET_SPARSE`. No BCD or partition changes.
wootc opens a local TCP loopback socket (`127.0.0.1:9099`) or a
named pipe to receive progress events from the guest.

**2. Builder Launch (host → guest)**

wootc launches the bundled QEMU binary **headless** (`-display none`),
booting the micro-Alpine kernel and initramfs directly with `preview.raw`
mapped as a VirtIO block device:

```
qemu-system-x86_64.exe
  -display none                    # no window during build
  -m 2G                            # builder needs 2GB (RAM-backed podman)
  -kernel builder-vmlinuz
  -initrd builder-initramfs.img
  -drive file=preview.raw,format=raw,if=virtio
  -chardev socket,id=ipc,host=127.0.0.1,port=9099
  -device virtio-serial
  -device virtserialport,chardev=ipc,name=wootc.ipc
```

**3. In-Memory OCI Processing (guest)**

The Alpine initramfs boots in sub-second time entirely out of RAM.
The embedded startup script:

1. **IPC handshake** — opens `/dev/virtio-ports/wootc.ipc`, sends a
   JSON progress event (`{"step":"pulling","pct":0}`) back to the
   Windows GUI to advance the frontend progress bar.
2. **RAM-backed podman** — configures podman with the `vfs` storage
   driver on a tmpfs mount to avoid wearing the disk or requiring
   secondary storage during OCI layer extraction.
3. **Target detection** — identifies the VirtIO block device
   (`/dev/vda`) mapped from `preview.raw`.
4. **Deployment** — runs:
   ```bash
   podman pull "${IMAGE_REF}"
   podman run --rm --privileged \
       -v /dev:/dev \
       "${IMAGE_REF}" \
       bootc install to-disk --generic-image --via-loopback /dev/vda
   ```
   This partitions `/dev/vda`, configures sub-volumes if btrfs,
   handles filesystem generation, and unpacks the immutable
   deployment trees directly onto the virtual disk.

#### Stage 2: Graceful Teardown & Interactive Preview

**4. Handoff Signal (guest → host)**

Once `bootc install` returns clean (exit code 0), the Alpine script
sends `STATUS=SUCCESS` over the VirtIO serial channel and executes
`poweroff -f`.

Back on the host, wootc.exe:
- Traps the closure of the background QEMU process handle
- Closes the loopback IPC socket
- Verifies the integrity of `preview.raw`

**5. Interactive Preview Launch**

wootc immediately spawns a **fresh**, user-visible QEMU instance.
The Alpine builder components are dropped entirely. The new instance
targets `preview.raw` with full hardware visualization and native
OVMF UEFI firmware:

```
qemu-system-x86_64.exe
  -accel whpx
  -m 4G -smp 4
  -drive file=preview.raw,format=raw,if=virtio
  -nic user,hostfwd=tcp::2222-:22
  -bios edk2-x86_64-code.fd
  -display gtk
```

The window appears on the user's desktop showing the GRUB bootloader
menu of the target distribution loading directly off the virtual disk.

#### Engineering Nuances

**RAM sizing**: The builder phase requires at least **2GB** allocated
to the VM. Podman pulls compressed OCI layers into a RAM-backed tmpfs
before extracting them sequentially onto the raw target drive. A
standard 512MB or 1GB mini-initramfs footprint will run out of
allocatable memory mid-stream. Once deployment finishes, the
interactive preview scales up to **4GB** for comfortable desktop use.

**Live commit bridge**: If the user experiments inside the interactive
preview and clicks **[Install for Real]** on the Windows GUI:

1. wootc stops the interactive QEMU session.
2. Instead of running a fresh OCI pull, it reuses the built image.
3. Moves `%TEMP%\wootc-preview\preview.raw` → `C:\wootc\disks\root.disk`.
4. Configures the Windows Boot Manager entry targeting this image.

On the next bare-metal reboot, any settings changes, profile configs,
or package installations made inside the VM preview are preserved
perfectly — it's the same disk image.

**Bundled components:**

| Component | Size | Source |
|---|---|---|
| `qemu-system-x86_64.exe` | ~8 MB | [QEMU Windows builds](https://qemu.weilnetz.de/) (MSYS2) |
| `edk2-x86_64-code.fd` | ~2 MB | EDK2 OVMF UEFI firmware |
| `builder-vmlinuz` + `builder-initramfs.img` | ~15 MB | Alpine with podman, skopeo, bootc |
| **Total bundled** | **~25 MB** |

### 6.2 Boot Existing root.disk as VM

If the user already has a dual-boot wootc install, they can boot that
same root.disk directly in QEMU — running their Linux system inside
Windows without rebooting. The same image, same state, same files.

```
┌──────────────────────────────────────────────────┐
│ wootc — Your Linux is already installed            │
│                                                    │
│  Boot your existing TunaOS system in a VM:          │
│                                                    │
│  Source: C:\wootc\disks\root.disk (40 GB)           │
│                                                    │
│  This is your actual Linux system. Changes          │
│  made in the VM persist on disk.                    │
│                                                    │
│  [Boot in VM]  [Reboot to Linux]  [Cancel]         │
└──────────────────────────────────────────────────┘
```

**Implementation** — QEMU boots the root.disk file directly:

```
qemu-system-x86_64.exe
  -accel whpx
  -m 4G -smp 4
  -drive file=C:\wootc\disks\root.disk,format=raw,if=virtio
  -nic user,hostfwd=tcp::2222-:22
  -bios edk2-x86_64-code.fd
  -display gtk
```

The root.disk already has a GPT partition table, ESP, and root filesystem
— all set up by fisherman during the initial deployer run. QEMU boots it
like any raw disk image.

**When the user is already dual-booting and wants to switch:**

| From | To | How |
|---|---|---|
| Windows | Linux (VM) | QEMU boots root.disk in a window |
| Windows | Linux (native) | Reboot → dual-boot via GRUB2 |
| Linux (native) | Windows | Reboot → Windows Boot Manager |
| Linux (VM) | Windows | Close QEMU window |

**Shared state**: both the VM and the dual-boot path use the same
root.disk. Changes in one appear in the other — it's the same filesystem.
The only difference is whether the kernel runs on bare metal or inside
QEMU.

### 6.3 Boot a Real Partition as VM

After migration to a native partition (e.g. D: is now a real Linux
filesystem, not a loop file), QEMU can still boot it:

```
# Boot from raw partition D:
qemu-system-x86_64.exe
  -accel whpx
  -drive file=\\.\D:,format=raw,if=virtio
  -nic user,hostfwd=tcp::2222-:22
  -bios edk2-x86_64-code.fd
  -display gtk
```

`\\.\D:` is the Windows raw device path for the D: volume.

> **Warning**: This gives QEMU direct block-level access to the partition.
> Do not simultaneously mount D: in Windows while it's in use by QEMU —
> that guarantees filesystem corruption. wootc ensures Windows doesn't
> mount the partition before starting QEMU by removing the drive letter
> temporarily.

### 6.4 VM-to-Native Bridge

Both VM modes share the same disk image as the dual-boot install.
If the user tries a fresh VM and clicks **[Install for Real]**:

1. QEMU shuts down.
2. `%TEMP%\wootc-preview\preview.raw` is moved to `C:\wootc\disks\root.disk`
   (no re-download, no re-deployment).
3. GRUB2 and BCD entries are set up.
4. User reboots into the same system — all VM-made changes are preserved.

The reverse is also true: a system installed via dual-boot can be booted
in a VM at any time via §6.2.

## 7. License

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
| [fisherman](https://github.com/tuna-os/fisherman) | Disk partitioning, bootc install, data slurp | Apache-2.0 |
| [bootc](https://github.com/containers/bootc) | Container-native OS install and updates | Apache-2.0 |
| [bootupd](https://github.com/coreos/bootupd) | Bootloader installation (invoked by bootc) | Apache-2.0 |
| [podman](https://github.com/containers/podman) | OCI image pull and container execution | Apache-2.0 |
| [skopeo](https://github.com/containers/skopeo) | Image inspection, OCI layout export | Apache-2.0 |

---

## 8. Architecture: Two-Layer Design

wootc has a strict architectural boundary between platform tooling and
the bootc payload:

```
┌─────────────────────────────────────────────────┐
│                  wootc.exe                        │
│           (Windows installer frontend)            │
└──────────────┬────────────────────┬──────────────┘
               │                    │
    ┌──────────▼──────────┐  ┌─────▼──────────────┐
    │  Platform Tooling    │  │  bootc Payload      │
    │  (generic, reusable) │  │  (bootc-specific)   │
    │                      │  │                     │
    │  • QEMU + WHPX       │  │  • Fisherman recipes │
    │  • GRUB2 chainload   │  │  • OCI image pull    │
    │  • BCD manipulation  │  │  • bootc install     │
    │  • ESP management    │  │  • Migration (slurp) │
    │  • NTFS mount/loop   │  │  • Passthrough       │
    │  • WinRM automation  │  │  • Flatpak injection │
    │  • VM modes          │  │                     │
    │                      │  │                     │
    │  Works with ANY      │  │  Requires bootc-    │
    │  Linux, not just     │  │  based images       │
    │  bootc-based ones    │  │                     │
    └──────────────────────┘  └─────────────────────┘
```

**Why this boundary matters:**

- The platform layer could be reused to boot any Linux (Ubuntu loop-file,
  Arch VM, Fedora dual-boot) — it's generic infrastructure.
- The payload layer is what makes it wootc instead of Wubi2.
- Testing is cleaner: platform tests don't need OCI registries, payload
  tests don't need Windows.
- Dependencies flow one way: payload depends on platform, never vice versa.

### 8.1 Directory Layout

```
wootc/
├── platform/                      ← GENERIC LINUX/WINDOWS TOOLING
│   ├── grub/
│   │   ├── wubildr-bootstrap.cfg
│   │   ├── wubildr.cfg
│   │   └── grub.install.cfg
│   ├── dracut/
│   │   └── 99wootc-boot/          ← loop-root boot (works for any Linux)
│   │       ├── module-setup.sh
│   │       ├── wootc-parse-cmdline.sh
│   │       └── wootc-mount-loop.sh
│   ├── qemu/                       ← QEMU bundling + VM management
│   │   └── (to be built)
│   └── windows/                    ← BCD, ESP, NTFS, WinRM
│       └── (to be built)
│
├── payload/                        ← BOOTC-SPECIFIC PAYLOAD
│   ├── deployer/
│   │   ├── Containerfile
│   │   ├── deploy.sh              ← finds root.disk → fisherman recipe
│   │   ├── init
│   │   └── module-setup.sh
│   ├── migration/
│   │   └── (wootc-passthrough.service, slurp configs)
│   └── recipes/
│       └── (image catalogs, default recipes)
│
├── fisherman/                      ← git submodule: tuna-os/fisherman
├── tests/
│   ├── e2e/                        ← full KVM e2e test
│   └── unit/                       ← platform + payload unit tests
├── docs/
│   └── SPEC.md
├── .github/workflows/
│   ├── ci.yml
│   └── e2e-kvm.yml
└── README.md
```

### 8.2 Key Dependencies

| Project | Role | License |
|---|---|---|
| [WubiUEFI](https://github.com/hakuna-m/wubiuefi) | Windows installer, BCD, GRUB core images | GPL-2.0 |
| [fisherman](https://github.com/tuna-os/fisherman) | Disk partitioning, bootc install, data slurp | Apache-2.0 |
| [bootc](https://github.com/containers/bootc) | Container-native OS install and updates | Apache-2.0 |
| [bootupd](https://github.com/coreos/bootupd) | Bootloader installation (invoked by bootc) | Apache-2.0 |
| [podman](https://github.com/containers/podman) | OCI image pull and container execution | Apache-2.0 |
| [skopeo](https://github.com/containers/skopeo) | Image inspection, OCI layout export | Apache-2.0 |

---

## 9. Open Questions

#### Which Microsoft UEFI CA the firmware trusts (#322)

Secure Boot launches only a loader signed by a certificate authority present
in the firmware's `db` variable. Microsoft's third-party authority exists in
two generations:

| Generation | Certificate | Notes |
|---|---|---|
| `Microsoft Corporation UEFI CA 2011` | expired 2026-06-27 | firmware ignores expiry, so machines holding it still boot 2011-signed loaders |
| `Microsoft UEFI CA 2023` | current | signs everything Microsoft issues now; new machines increasingly ship it alone |

A shim signed only by an authority this firmware does not hold fails at
`bad shim signature` **after** the reboot, and the firmware falls back to
Windows with nothing said. wootc therefore closes the loop at both ends:

- **Build time.** `packaging/shim-authorities.py` reads the Authenticode
  signatures out of the staged `shimx64.efi` (walking *every* WIN_CERTIFICATE,
  since a dual-signed binary carries two) and writes `shim-authorities.json`.
  The release refuses to publish a shim that is not 2023-signed, and stamps
  the generations into each exe with `-X main.shimAuthorities=…`.
- **Preflight.** `getSystemInfo` reads `db` via `Get-SecureBootUEFI -Name db`,
  parses the `EFI_SIGNATURE_LIST` chain, and records which generations the
  firmware holds. `gateScenario` refuses **before** anything is written when
  both sides are known and do not intersect.
- **When `db` cannot be read**, the install proceeds with an on-screen
  warning rather than a refusal. `bad shim signature` costs the user a reboot
  back into Windows, not their data; refusing every PC whose SecureBoot
  PowerShell module is unavailable would block machines that work today.
  (This is a deliberate softening of the original design in
  `docs/borrowed-from-libertix.md` §1, which called for refusing on unknown.)

`mmx64.efi` (MokManager) is signed by the distribution's own key and verified
by shim rather than by the firmware, so it is deliberately not graded against
the Microsoft authorities.

1. **Secure Boot with GRUB2**: WubiUEFI uses shim for Secure Boot.
   wootc inherits this for the GRUB2 path. The shim must be signed by
   Microsoft's 3rd-party UEFI CA (the standard path for community
   distributions). Machine Owner Keys (MOK) enrollment via `mokutil`
   is the fallback for custom or localized keys — the user sees the
   blue MOK management screen on first boot, enrolls the wootc key,
   and Secure Boot works thereafter.

   Signing pipeline: wootc's build system signs the GRUB2 EFI binary
   (`grubx64.efi`) with the project's Secure Boot key. The signed
   binary + shim are placed on the ESP. For `systemd-boot`, UKIs
   are signed directly with the same key — no shim needed.

   Key management: the private signing key is held in CI secrets
   (GitHub Actions encrypted secrets) and used only during release
   builds. The public certificate is embedded in the shim for MOK
   enrollment fallback.

2. **ARM64 Windows**: WubiUEFI supports x86_64 only. ARM64 Windows devices
   (Surface Pro X, etc.) use a completely different boot chain. Deferred.

3. **systemd-boot kernel sync hook**: The OSTree transaction hook
   that copies kernels from inside root.disk to the ESP needs to handle
   the case where root.disk is not yet mounted at hook execution time.
   May need to be a systemd path unit instead.

4. **root.vhdx vs root.disk**: VHDX includes an internal allocation log
   that guards against block metadata corruption during sudden power
   failures. Unlike raw disk images, a VHDX file can be natively
   mounted inside Windows Disk Management for recovery without booting
   a Linux live environment. The tradeoff: slightly larger file size
   (~5MB metadata overhead) and the need to use `qemu-nbd` or a
   VHDX-aware loop driver on Linux. Elevated to post-MVP priority
   given the recovery UX benefits.

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
podman build -f payload/deployer/Containerfile -t wootc-deployer .
mkdir -p payload/deployer/out
podman run --rm --entrypoint /bin/cat localhost/wootc-deployer \
    /out/initramfs.img > payload/deployer/out/initramfs.img
podman run --rm --entrypoint /bin/cat localhost/wootc-deployer \
    /out/vmlinuz > payload/deployer/out/vmlinuz

# Full e2e test (requires KVM)
cd tests/e2e && ./run-e2e.sh

# CI-only tests (no KVM needed)
shellcheck --severity=warning payload/deployer/*.sh platform/dracut/99wootc-boot/*.sh tests/e2e/run-e2e.sh
```
