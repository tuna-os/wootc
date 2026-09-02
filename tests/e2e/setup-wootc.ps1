# setup-wootc.ps1
# Runs inside the Windows VM via WinRM.
# Creates root.disk, copies deployer files, installs GRUB, configures BCD.
#
# Assumes deployer files are available at D:\ (shared volume mapped
# by dockur/windows as a CD-ROM or network drive).
#
# In the test environment, dockur/windows can expose /wootc as:
#   - A Samba share at \\host.lan\wootc
#   - Or we copy files in via a custom script

param(
    [string]$ImageRef = "ghcr.io/tuna-os/yellowfin:gnome",
    [string]$Hostname = "wootc-test",
    # 35 GB: holds the extracted ostree deployment + install headroom. GNOME
    # images (~10 GB) fit in 25, but the larger KDE/niri desktops ENOSPC'd
    # `bootc install to-filesystem` there — el10-kde AND fedora-kde failed at
    # 25 while both GNOME variants passed (GH matrix 20260724). The GUI path
    # already defaults to 40; 35 covers every catalog desktop without
    # over-inflating the fully-allocated root.disk on tight hosted runners.
    [int]$DiskSizeGB = 35,
    # Phase-2 bootloader the deployer installs: "grub2" (traditional ostree),
    # "systemd" (composefs-native), or "auto" (default) to let the DEPLOYER
    # detect it definitively from the image (grub in bootupd → grub2, else
    # systemd). Passed through as wootc.bootloader=.
    [ValidateSet("grub2", "systemd", "auto")]
    [string]$Bootloader = "auto",
    # composefs native backend; adds wootc.composefs=1.
    # composefs-sealed ostree images (e.g. yellowfin) do NOT need this —
    # the deployer auto-detects the backend from the image.
    [switch]$ComposeFs,
    # Root filesystem axis (#35): "auto" (default) lets the deployer pick
    # (xfs unsealed / ext4 sealed); an explicit value is passed through as
    # wootc.filesystem= so the matrix can exercise btrfs.
    [ValidateSet("xfs", "ext4", "btrfs", "auto")]
    [string]$Filesystem = "auto",
    # In the E2E image, Dockur copies /oem to C:\OEM. Supplying this path
    # makes setup self-contained and avoids requiring SMB/WinRM to be ready.
    [string]$PayloadDir = "",
    # Fault-injection axis (#288): injects simulated failure or cancellation
    # at an install boundary: "root-disk", "image-pull", "efi-staging", "bcd-arming", "pre-reboot".
    [ValidateSet("root-disk", "image-pull", "efi-staging", "bcd-arming", "pre-reboot", "")]
    [string]$FaultInject = ""
)

$ErrorActionPreference = "Stop"

# ── Single-instance guard ───────────────────────────────────────────────────
# On a FRESH install two launchers race: Windows autologon fires the OEM
# handoff at first logon AND the harness dispatches it over QGA. Both run
# setup-wootc.ps1 concurrently, and the second hits "Access to the path
# 'C:\wootc\install\<file>' is denied" on whatever file the first is writing
# (grub.install.cfg, then wubildr.cfg, … — an endless whack-a-mole). A global
# mutex makes exactly one instance proceed; the loser exits cleanly. This is
# the real fix for the whole "OEM setup failed before the barrier" class.
$script:wootcMutex = New-Object System.Threading.Mutex($false, 'Global\wootc-setup-wootc')
try { $gotMutex = $script:wootcMutex.WaitOne(0) } catch { $gotMutex = $true }
if (-not $gotMutex) {
    Write-Host "[wootc] another setup-wootc.ps1 already holds the lock — this instance exits (single-instance guard)."
    exit 0
}

# Extra deployer kargs for the bootloader/composefs axes of the test matrix.
# Both default to "auto": the deployer probes the image and picks the backend
# definitively. An explicit override is an Advanced choice.
$WootcKargs = "wootc.bootloader=$Bootloader"
if ($ComposeFs) { $WootcKargs += " wootc.composefs=1" }
if ($Filesystem -ne "auto") { $WootcKargs += " wootc.filesystem=$Filesystem" }
# ── BitLocker / FDE (SPEC §3.5) ─────────────────────────────────────────────
# The deployer mounts the host NTFS from Linux; on a BitLocker-protected C: it
# would see FVE ciphertext, so root.disk cannot live there. We never force a
# decrypt — instead shrink C: and host Linux on a new UNENCRYPTED volume, which
# is exactly what the installer GUI offers. On a plaintext C: this is a no-op.
$storageRoot = "C:"
$blState = "off"
try {
    $bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
    if ($bl) {
        if ($bl.VolumeStatus -eq 'EncryptionInProgress') { $blState = 'encrypting' }
        elseif ($bl.ProtectionStatus -eq 'On') { $blState = 'on' }
    }
} catch { $blState = "off" }
Write-Host "[wootc] C: BitLocker state: $blState"

if ($blState -ne 'off') {
    Write-Host "[wootc] C: is protected — creating an unencrypted volume for Linux (no decrypt)"
    # root.disk is NOT the only thing that lands on this volume. The deployer
    # also creates a 20 GiB ext4 scratch image next to it
    # (wootc/cache/deployer-scratch.img — ntfs3 has no sparse support, so it is
    # fully allocated) plus the image cache and logs. Carving only
    # DiskSizeGB + 6 gave a 41 GiB volume for 35 GiB of root.disk + 20 GiB of
    # scratch, so the deployer ran the volume out of space and ground silently
    # until the 90-minute budget expired (BitLocker cells, runs 30165015199 /
    # 30173452904 / 30177404786 — no VDL progress lines, so it never even
    # reached the root.disk write). Non-BitLocker cells never hit this because
    # root.disk lives on a roomy C:.
    $scratchGiB = 20
    $headroomGiB = 6
    $needBytes = ([int64]$DiskSizeGB + $scratchGiB + $headroomGiB) * 1GB
    Write-Host "[wootc] Carving $([int64]$DiskSizeGB + $scratchGiB + $headroomGiB) GiB for Linux (root.disk ${DiskSizeGB}G + scratch ${scratchGiB}G + ${headroomGiB}G headroom)"
    $cPart = Get-Partition -DriveLetter C
    $sup   = Get-PartitionSupportedSize -DriveLetter C
    $target = $cPart.Size - $needBytes
    if ($target -lt $sup.SizeMin) {
        throw "Not enough room on C: to carve an unencrypted volume for Linux"
    }
    Resize-Partition -DriveLetter C -Size $target
    $newPart = New-Partition -DiskNumber $cPart.DiskNumber -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $newPart -FileSystem NTFS -NewFileSystemLabel "wootc-data" -Confirm:$false | Out-Null
    $storageRoot = "$($newPart.DriveLetter):"

    # Windows 11 Device Encryption auto-encrypts NEWLY CREATED fixed volumes, so
    # the volume we just carved comes back BitLocker-protected and root.disk
    # becomes unreadable to the deployer. That is #34: the scan verdict showed
    # BOTH sda3 (C:) and sda4 (this volume) as TYPE=BitLocker, so the deployer
    # correctly skipped the ciphertext and reported "Could not find root.disk on
    # any partition" while root.disk sat inside the encrypted sda4.
    # Force protection off and WAIT — decryption is asynchronous.
    # Wait for FULLY DECRYPTED, not merely "protection off". A volume reports
    # ProtectionStatus=Off the moment Disable-BitLocker is accepted while
    # VolumeStatus stays DecryptionInProgress for minutes afterwards. Proceeding
    # then reboots into the deployer, which writes a 35 GB root.disk onto a
    # volume Windows is still decrypting underneath it: the deploy pegs the CPU
    # with a silent serial and blows its 90-minute budget
    # (fedora-gnome-win11pro-bitlocker, GH run 30165015199 — 89 min at ~90% CPU
    # with no deployer output after the block-device table).
    # The volume is freshly formatted and empty, so this should be quick; give it
    # a real budget anyway and report progress so a slow decrypt is visible.
    Write-Host "[wootc] Ensuring $storageRoot stays unencrypted (Device Encryption auto-protects new volumes)..."
    # The verdict must be STABLE, not merely momentary. A freshly created volume
    # reports one of two transient states that both used to end this loop on its
    # first pass, before Disable-BitLocker had been called even once:
    #   - Get-BitLockerVolume returns nothing at all (object not yet materialised)
    #   - it returns FullyDecrypted/Off, and Device Encryption starts encrypting
    #     moments later
    # Either way the gate below then read EncryptionInProgress and threw ~24s
    # into the run (el10-gnome-win11pro-bitlocker, 20260727T002633Z: the guest
    # logged "Ensuring E: stays unencrypted" and then went straight to the throw
    # with no per-iteration progress line, because the loop body never ran).
    # Require the clean reading twice in a row, and treat "no object" the same
    # way — a volume genuinely without BitLocker stays null on every look.
    $deadline = (Get-Date).AddMinutes(30)
    $v = $null
    $cleanStreak = 0
    while ((Get-Date) -lt $deadline) {
        $v = Get-BitLockerVolume -MountPoint $storageRoot -ErrorAction SilentlyContinue
        if ((-not $v) -or ($v.ProtectionStatus -eq 'Off' -and $v.VolumeStatus -eq 'FullyDecrypted')) {
            $cleanStreak++
            if ($cleanStreak -ge 2) { break }
            Write-Host "[wootc]   $storageRoot looks clear (status=$($v.VolumeStatus) protection=$($v.ProtectionStatus)) — confirming"
            Start-Sleep -Seconds 10
            continue
        }
        $cleanStreak = 0
        try { Disable-BitLocker -MountPoint $storageRoot -ErrorAction SilentlyContinue | Out-Null } catch {}
        Write-Host "[wootc]   $storageRoot status=$($v.VolumeStatus) protection=$($v.ProtectionStatus) pct=$($v.EncryptionPercentage)"
        Start-Sleep -Seconds 10
    }
    $v = Get-BitLockerVolume -MountPoint $storageRoot -ErrorAction SilentlyContinue
    if ($v) {
        Write-Host "[wootc] $storageRoot BitLocker: status=$($v.VolumeStatus) protection=$($v.ProtectionStatus)"
        if ($v.ProtectionStatus -ne 'Off' -or $v.VolumeStatus -ne 'FullyDecrypted') {
            throw "BitLocker on $storageRoot is not fully decrypted (status=$($v.VolumeStatus) protection=$($v.ProtectionStatus)) — the deployer would write root.disk onto a decrypting volume"
        }
    } else {
        Write-Host "[wootc] $storageRoot has no BitLocker volume object (plaintext)"
    }
    Write-Host "[wootc] Linux will live on unencrypted volume $storageRoot (C: stays encrypted)"
}
Write-Host "[wootc] WOOTC_STORAGE_ROOT=$storageRoot"

$wootcDir = "$storageRoot\wootc"
$installDir = "$wootcDir\install"
$disksDir = "$wootcDir\disks"

Write-Host "[wootc] Setting up wootc test environment..."

# ── Step 1: Create directory structure ──────────────────────────────────────
Write-Host "[wootc] Creating directories..."
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
New-Item -ItemType Directory -Force -Path $disksDir | Out-Null

# ── Step 2: Create root.disk (SPARSE RAW image) ─────────────────────────────
# Raw, not VHDX, and the reason is the Linux side.
#
# A VHDX needs a format-aware driver to attach — qemu-nbd — which target bootc
# images do not ship. Verified against ghcr.io/tuna-os/yellowfin:gnome:
#     /usr/sbin/losetup   PRESENT
#     qemu-nbd            ABSENT
# So VHDX forced us to stage a foreign Fedora qemu-nbd plus its 26-library
# closure and loader into an initramfs assembled from the TARGET image's
# libraries. That produced a libfuse3.so.4-vs-.so.3 soname mismatch, a wrapper,
# an execute-test, and a silent death inside the staging that cost most of a day
# to localise.
#
# A raw image needs only `losetup --partscan`, the kernel loop driver, which is
# already present. Nothing to stage, nothing to go wrong across image
# boundaries. It is also what Wubi used, which is why this file is still called
# root.disk everywhere.
#
# It also removes the VHDX format driver from the boot-critical WRITE path, and
# with it QEMU's VHDX corruption reports — notably corruption on EXPANSION
# (gitlab #727), which is exactly what a dracut regen writing a ~130 MB
# initramfs does.
#
# NTFS sparse files give the same "allocate on write" behaviour as a dynamic
# VHDX, so the disk cost is unchanged.
Write-Host "[wootc] Creating root.disk ($DiskSizeGB GB preallocated raw image)..."
$diskPath = "$disksDir\root.disk"
$sizeBytes = [int64]$DiskSizeGB * 1GB

# Create a 100% physically allocated raw image file.
# SetLength alone creates a sparse NTFS file (VDL stays at 0).
# fsutil file setvaliddata forces VDL = file size, allocating real disk clusters.
# Without this Linux kernel ntfs3 hits EIO on every write past VDL on loop0.
if (Test-Path $diskPath) {
    Remove-Item $diskPath -Force
}
$fs = [System.IO.File]::Create($diskPath)
try   { $fs.SetLength($sizeBytes) }
finally { $fs.Close() }

if (-not (Test-Path $diskPath)) { throw "Failed to create raw image at $diskPath" }
$actual = (Get-Item $diskPath).Length
if ($actual -ne $sizeBytes) {
    throw "root.disk is $actual bytes, expected $sizeBytes"
}
Write-Host "[wootc] root.disk file created: $actual bytes, extending VDL..."
# fsutil setvaliddata requires SeManageVolumePrivilege (held by SYSTEM).
$fsutilOut = & fsutil file setvaliddata $diskPath $sizeBytes 2>&1
Write-Host "[wootc] fsutil setvaliddata: $fsutilOut"
if ($LASTEXITCODE -ne 0) {
    throw "fsutil file setvaliddata failed (exit $LASTEXITCODE): $fsutilOut"
}
Write-Host "[wootc] root.disk VDL extended to full $DiskSizeGB GB: $diskPath"

Write-Host "[wootc] root.disk created: $diskPath ($DiskSizeGB GB dynamic VHDX)"

if ($FaultInject -eq "root-disk") {
    Write-Host "[wootc] Injected fault at boundary: root-disk"
    $st = @{ state = "failed"; phase = "root-disk"; error = "fault-injection: simulated failure during root disk creation"; updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"); updatedBy = "setup-wootc" } | ConvertTo-Json -Compress
    Set-Content -Force -Path "$wootcDir\state.json" -Value $st -Encoding UTF8
    throw "fault-injection: simulated failure during root disk creation"
}

# ── Step 3: Copy deployer files ─────────────────────────────────────────────
# Files should be available via a shared volume or SMB.
# In the test harness, we use dockur/windows custom CD-ROM mount
# or copy them via WinRM file copy.

Write-Host "[wootc] Looking for deployer files..."

# Strategy 1: Check if wootc share is mounted
# dockur/windows mounts /wootc as a Samba share accessible at \\host.lan\wootc
# or via IP at \\10.0.2.2\wootc (QEMU user-mode networking default)

$deployerVmlinuz = $null
$deployerInitramfs = $null
$grubDir = $null
$payloadRoot = $null

if ($PayloadDir) {
    Write-Host "[wootc] Trying local payload: $PayloadDir"
    if (Test-Path "$PayloadDir\deployer-vmlinuz") {
        $deployerVmlinuz = "$PayloadDir\deployer-vmlinuz"
        $deployerInitramfs = "$PayloadDir\deployer-initramfs.img"
        $grubDir = "$PayloadDir\grub"
        $payloadRoot = $PayloadDir
        Write-Host "[wootc] Found local deployer files at $PayloadDir"
    }
}

# Try Samba share
# Strategy 1: Check dockur/windows Samba share
# dockur/windows mounts /shared as \\host.lan\Data
# We mount our wootc-files at /shared in the container

$sharePaths = @(
    "\\host.lan\Data",
    "\\10.0.2.2\Data"
)

if (-not $deployerVmlinuz) {
    foreach ($share in $sharePaths) {
        Write-Host "[wootc] Trying Samba share: $share"
        # Try to list the share to verify access
        $result = net use $share 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[wootc] Share $share not accessible, trying next..."
            continue
        }
        if (Test-Path "$share\deployer-vmlinuz") {
            Write-Host "[wootc] Found deployer files at $share"
            $deployerVmlinuz = "$share\deployer-vmlinuz"
            $deployerInitramfs = "$share\deployer-initramfs.img"
            $grubDir = "$share\grub"
            $payloadRoot = $share
            break
        }
    }
}

if (-not $deployerVmlinuz) {
    Write-Error "Could not find deployer files via Samba share"
    exit 1
}

# Copy deployer files
Write-Host "[wootc] Copying deployer kernel..."
Copy-Item $deployerVmlinuz "$installDir\deployer-vmlinuz" -Force

Write-Host "[wootc] Copying deployer initramfs..."
Copy-Item $deployerInitramfs "$installDir\deployer-initramfs.img" -Force
if ($payloadRoot -and (Test-Path "$payloadRoot\e2e-phase3")) {
    Copy-Item "$payloadRoot\e2e-phase3" "$installDir\e2e-phase3" -Force
}
# Optional registry-mirror hint for the deployer (E2E bandwidth relief);
# the deployer probes it and silently pulls direct when absent/dead.
if ($payloadRoot -and (Test-Path "$payloadRoot\mirror.txt")) {
    Copy-Item "$payloadRoot\mirror.txt" "$installDir\mirror.txt" -Force
}

if ($FaultInject -eq "image-pull") {
    Write-Host "[wootc] Injected fault at boundary: image-pull (simulating interrupted image pull)"
    New-Item -ItemType Directory -Force -Path "$wootcDir\bundle\oci\blobs\sha256" | Out-Null
    Set-Content -Path "$wootcDir\bundle\oci\blobs\sha256\partialblob.part" -Value "INCOMPLETE_BLOB" -Encoding ASCII
    $st = @{ state = "failed"; phase = "image-pull"; error = "fault-injection: simulated failure during image download"; updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"); updatedBy = "setup-wootc" } | ConvertTo-Json -Compress
    Set-Content -Force -Path "$wootcDir\state.json" -Value $st -Encoding UTF8
    throw "fault-injection: simulated failure during image download"
}

# ── Credential vault (SPEC: vault.json) ─────────────────────────────────────
# Create the Linux user "wootc" — the SAME name as the Windows profile, which
# is what the User Data Bridge keys on (wootc-mount-user-dirs binds
# /host/Users/<name> into the home of the MATCHING Linux account). Without a
# vault the deployer creates no user at all and the whole data-persistence
# chain is untestable. Password is "wootc-e2e" as a precomputed $6$ SHA-512
# hash (test-only credential; the deployer shreds vault.json before install).
Write-Host "[wootc] Writing credential vault (user: wootc)..."
$vaultJson = @"
{
  "username": "wootc",
  "password_hash": "`$6`$wootce2e`$cBsKHH8DC/MXaiDn6AJUbdjZuwjULMiS2.20qDARI7Pl9rjJpiaTtxkOSobqW9CE0NJvq9PRgaK0AaTg8WT7J1",
  "hostname": "wootc-test"
}
"@
Set-Content -Force -Path "$installDir\vault.json" -Value $vaultJson -Encoding ASCII
$WootcKargs += " wootc.vault=/wootc/install/vault.json"

# ── BitLocker recovery key (SPEC §3.5, #61) ──────────────────────────────────
# When C: is BitLocker-protected, capture the numerical recovery password
# so Phase 2 can unlock C: and the User Data Bridge can find the real user
# profiles that live there (they are on C:, not on the unencrypted data
# volume where root.disk sits). The deployer shreds this file alongside
# vault.json; the bridge reads it to unlock C: with cryptsetup bitlkOpen.
if ($blState -ne 'off') {
    Write-Host "[wootc] C: is BitLocker-protected — capturing recovery key for the User Data Bridge (#61)"
    try {
        $kp = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue |
              Select-Object -ExpandProperty KeyProtector -ErrorAction SilentlyContinue |
              Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
              Select-Object -First 1
        if ($kp -and $kp.RecoveryPassword) {
            $rawKey = $kp.RecoveryPassword -replace '-', ''
            if ($rawKey.Length -eq 48) {
                Set-Content -Force -Path "$installDir\bitlocker-key.txt" -Value $kp.RecoveryPassword -Encoding ASCII
                Write-Host "[wootc] BitLocker recovery key stored at $installDir\bitlocker-key.txt"
            } else {
                Write-Host "[wootc] WARNING: recovery password is $($rawKey.Length) chars (expected 48) — bridge will not unlock C:"
            }
        } else {
            # Fallback: manage-bde -protectors -get C:
            $mbRaw = & manage-bde -protectors -get C: 2>$null | Out-String
            if ($mbRaw -match 'Password:\s*\r?\n\s*([0-9-]+)') {
                $mbKey = $matches[1]
                Set-Content -Force -Path "$installDir\bitlocker-key.txt" -Value $mbKey -Encoding ASCII
                Write-Host "[wootc] BitLocker recovery key stored (via manage-bde fallback) at $installDir\bitlocker-key.txt"
            } else {
                Write-Host "[wootc] WARNING: could not extract BitLocker recovery key — bridge will not unlock C:"
            }
        }
    } catch {
        Write-Host "[wootc] WARNING: BitLocker recovery key capture failed: $_"
    }
}

# ── Step 4: Copy GRUB files ─────────────────────────────────────────────────
if ($grubDir) {
    # GRUB cfg files from the wootc repo (legacy, for NTFS-based install)
    Copy-Item "$grubDir\*" $installDir -Force -ErrorAction SilentlyContinue

    # Copy signed EFI binaries from share to install dir for ESP staging
    $shimSrc = "$payloadRoot\shimx64.efi"
    $grubEfiSrc = "$payloadRoot\grubx64.efi"
    if ((Test-Path $shimSrc) -and (Test-Path $grubEfiSrc)) {
        Copy-Item $shimSrc "$installDir\shimx64.efi" -Force
        Copy-Item $grubEfiSrc "$installDir\grubx64.efi" -Force
        # MokManager (best-effort): shim launches it for the MOK enrollment
        # custom-kernel images queue during deploy (#248).
        if (Test-Path "$payloadRoot\mmx64.efi") {
            Copy-Item "$payloadRoot\mmx64.efi" "$installDir\mmx64.efi" -Force
        }
        Write-Host "[wootc] Copied signed shim + GRUB from share"
    } else {
        Write-Host "[wootc] WARNING: shimx64.efi and/or grubx64.efi not found on share"
        Write-Host "[wootc]   Secure Boot chain will be incomplete."
    }
}

# ── Step 5: Write GRUB install config ───────────────────────────────────────
# This is the first-boot GRUB menu that boots the deployer. Keep it as an
# explicit line array: Windows PowerShell's parser has proved less forgiving
# than pwsh when several interpolated here-strings and native interop coexist.
$grubInstallLines = @(
    '# wootc first-boot installer menu'
    'set default=0'
    'set timeout=5'
    ''
    'menuentry "Install wootc (automatic)" {'
    "    linux /wootc/install/deployer-vmlinuz wootc.image=$ImageRef wootc.hostname=$Hostname $WootcKargs quiet"
    '    initrd /wootc/install/deployer-initramfs.img'
    '}'
    ''
    'menuentry "Install wootc (debug)" {'
    "    linux /wootc/install/deployer-vmlinuz wootc.image=$ImageRef wootc.hostname=$Hostname $WootcKargs wootc.debug"
    '    initrd /wootc/install/deployer-initramfs.img'
    '}'
)

Set-Content -Force -Path "$installDir\grub.install.cfg" -Value $grubInstallLines -Encoding ASCII
Write-Host "[wootc] Wrote grub.install.cfg"

# ── Step 6: Write wubildr.cfg ───────────────────────────────────────────────
# Legacy GRUB config — Secure Boot uses the ESP-resident deployer menu. GRUB
# cannot loop-mount dynamic VHDX files, so Phase 2 is also loaded from the ESP.
$wubildrLines = @(
    'set show_panic_message=true'
    ''
    'if [ ${show_panic_message} = true ]; then'
    '    if search -s -f -n /wootc/install/grub.install.cfg; then'
    '        if configfile /wootc/install/grub.install.cfg; then'
    '            set show_panic_message=false'
    '        fi'
    '    fi'
    'fi'
    ''
    'if [ ${show_panic_message} = true ]; then'
    '    echo "wootc: Could not boot — installation may be incomplete."'
    '    echo "Please reboot into Windows and check C:\wootc\\"'
    'fi'
)

Set-Content -Force -Path "$installDir\wubildr.cfg" -Value $wubildrLines -Encoding ASCII
Write-Host "[wootc] Wrote wubildr.cfg"

# ── Step 7: Install signed shim + GRUB to ESP ──────────────────────────────
# Under Secure Boot, unsigned EFI binaries are rejected. Use the Fedora-signed
# shim → GRUB chain. Deployer kernel+initramfs go on the FAT32 ESP so GRUB can
# load them (the signed GRUB cannot load unsigned ntfs.mod).
Write-Host "[wootc] Setting up Secure Boot chain on ESP..."

# Find the EFI System Partition that actually backs Windows Boot Manager (#51).
# The BCD entry is cloned from {bootmgr} and inherits ITS device, so staging
# files on a different disk's ESP produces an install that looks complete and
# boots to a path that does not exist — while possibly overwriting another OS's
# boot partition. Resolve Windows' own system disk unambiguously from C:.
$sysDisk = (Get-Partition -DriveLetter C -ErrorAction SilentlyContinue).DiskNumber
if ($null -eq $sysDisk) {
    throw "Could not determine which disk Windows starts from; refusing to guess"
}
$espPart = Get-Partition -DiskNumber $sysDisk -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq "System" -or $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" } |
    Select-Object -First 1

if (-not $espPart) {
    throw ("No EFI System Partition found on the disk Windows starts from. " +
        "wootc will not write to another disk's boot partition, because the boot entry " +
        "it creates always points at Windows' own disk")
}

if (-not $espPart.DriveLetter) {
    Write-Host "[wootc] Assigning a drive letter to the EFI System Partition..."
    $espPart | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop
    $espPart = Get-Partition -DiskNumber $espPart.DiskNumber -PartitionNumber $espPart.PartitionNumber
}

$espDrive = $espPart.DriveLetter
if (-not $espDrive) {
    throw "EFI System Partition has no drive letter after assignment."
}
$espPath = "${espDrive}:" + [System.IO.Path]::DirectorySeparatorChar
Write-Host "[wootc] EFI System Partition mounted at $espPath"

# Create directory structure on ESP:
#   EFI/fedora/   — signed GRUB's embedded prefix (where grub.cfg is read)
#   EFI/wootc/    — deployer kernel + initramfs
New-Item -ItemType Directory -Force -Path "$espPath\EFI\fedora" | Out-Null
New-Item -ItemType Directory -Force -Path "$espPath\EFI\wootc" | Out-Null

# Copy the signed EFI chain.
if (Test-Path "$installDir\shimx64.efi") {
    Copy-Item "$installDir\shimx64.efi" "$espPath\EFI\fedora\shimx64.efi" -Force
    Write-Host "[wootc] Copied shimx64.efi to ESP:EFI/fedora/"
}
if (Test-Path "$installDir\grubx64.efi") {
    Copy-Item "$installDir\grubx64.efi" "$espPath\EFI\fedora\grubx64.efi" -Force
    Write-Host "[wootc] Copied grubx64.efi to ESP:EFI/fedora/"
}
if (Test-Path "$installDir\mmx64.efi") {
    Copy-Item "$installDir\mmx64.efi" "$espPath\EFI\fedora\mmx64.efi" -Force
    Write-Host "[wootc] Copied mmx64.efi (MokManager) to ESP:EFI/fedora/"
}

# Copy deployer kernel + initramfs to ESP (GRUB reads FAT32 but not NTFS).
if (Test-Path "$installDir\deployer-vmlinuz") {
    Copy-Item "$installDir\deployer-vmlinuz" "$espPath\EFI\wootc\deployer-vmlinuz" -Force
}
if (Test-Path "$installDir\deployer-initramfs.img") {
    Copy-Item "$installDir\deployer-initramfs.img" "$espPath\EFI\wootc\deployer-initramfs.img" -Force
}
Write-Host "[wootc] Deployer kernel + initramfs copied to ESP:EFI/wootc/"

# Write deployer grub.cfg to ALL candidate GRUB embedded-prefix directories.
# A previous wootc deployer run may have replaced the Fedora-signed grubx64.efi
# with the EL10/RHEL one (embedded prefix EFI/redhat rather than EFI/fedora).
# Write to all common vendor dirs so any grubx64.efi variant finds the correct config.
$grubCfgLines = @(
    '# wootc deployer - one-shot Linux installation',
    'set default=0',
    'set timeout=5',
    '',
    'menuentry "Install wootc (automatic)" {',
    "    linux /EFI/wootc/deployer-vmlinuz wootc.image=$ImageRef wootc.hostname=$Hostname $WootcKargs quiet console=ttyS0",
    '    initrd /EFI/wootc/deployer-initramfs.img',
    '}',
    '',
    'menuentry "Install wootc (debug)" {',
    "    linux /EFI/wootc/deployer-vmlinuz wootc.image=$ImageRef wootc.hostname=$Hostname $WootcKargs wootc.debug console=ttyS0",
    '    initrd /EFI/wootc/deployer-initramfs.img',
    '}'
)
$grubVendorDirs = @("$espPath\EFI\fedora", "$espPath\EFI\redhat", "$espPath\EFI\wootc")
# D1/D1c guard (#52): refuse to overwrite a grub.cfg that belongs to another
# OS. Only proceed if the file is absent or already wootc-owned (reinstall).
foreach ($gd in $grubVendorDirs) {
    $grubCfgPath = "$gd\grub.cfg"
    if (Test-Path $grubCfgPath) {
        $existing = Get-Content -Raw -Path $grubCfgPath -Encoding ASCII -ErrorAction SilentlyContinue
        if ($existing -and $existing -notmatch '# wootc') {
            throw "This PC already has a Linux bootloader at $grubCfgPath — installing wootc would break it. Dual-boot is not supported yet"
        }
    }
    New-Item -ItemType Directory -Force -Path $gd | Out-Null
    Set-Content -Force -Path $grubCfgPath -Value $grubCfgLines -Encoding ASCII
}
Write-Host "[wootc] Wrote deployer grub.cfg to ESP:EFI/{fedora,redhat,wootc}/grub.cfg"

if ($FaultInject -eq "efi-staging") {
    Write-Host "[wootc] Injected fault at boundary: efi-staging (simulating interrupted EFI staging)"
    $st = @{ state = "failed"; phase = "efi-staging"; error = "fault-injection: simulated failure during EFI staging"; updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"); updatedBy = "setup-wootc" } | ConvertTo-Json -Compress
    Set-Content -Force -Path "$wootcDir\state.json" -Value $st -Encoding UTF8
    throw "fault-injection: simulated failure during EFI staging"
}

# ── Step 8: Configure BCD ───────────────────────────────────────────────────
# Add a one-shot UEFI firmware entry pointing to the signed shim → GRUB chain.
# Every native bcdedit call is exit-code-checked; every observable must be proven
# before the setup-complete marker is written (#50).

Write-Host "[wootc] Configuring BCD..."

# Sweep any stale wootc firmware entries before creating a new one to guarantee idempotency on retry
$existingFw = (& bcdedit /enum firmware 2>&1) | Out-String
$re = [regex]'(?ms)identifier\s+(\{[0-9a-fA-F-]{36}\})[^{]*?description\s+wootc.*$'
foreach ($match in $re.Matches($existingFw)) {
    $oldGuid = $match.Groups[1].Value
    try { & bcdedit /set "{fwbootmgr}" displayorder $oldGuid /remove 2>&1 | Out-Null } catch {}
    try { & bcdedit /delete $oldGuid 2>&1 | Out-Null } catch {}
}

# Create a new BCD entry by cloning the Windows Boot Manager.
$bcdCreateOutput = (& bcdedit /copy "{bootmgr}" /d "wootc Deployer" 2>&1) | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "bcdedit /copy exited with code ${LASTEXITCODE}: $bcdCreateOutput"
}
Write-Host "[wootc] bcdedit copy: $bcdCreateOutput"

if ($bcdCreateOutput -match '\{([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\}') {
    $newGuid = "{$($Matches[1])}"
} else {
    throw "Could not parse GUID from bcdedit /copy output: $bcdCreateOutput"
}
Write-Host "[wootc] New BCD entry GUID: $newGuid"

# Persist the GUID so the E2E runner can re-arm the one-shot for Phase 2.
Set-Content -Force -Path "$installDir\bcd-guid.txt" -Value $newGuid -Encoding ASCII

if ($FaultInject -eq "bcd-arming") {
    Write-Host "[wootc] Injected fault at boundary: bcd-arming (simulating failure during BCD arming)"
    try { & bcdedit /deletevalue "{fwbootmgr}" bootsequence 2>&1 | Out-Null } catch {}
    if ($newGuid) {
        try { & bcdedit /set "{fwbootmgr}" displayorder $newGuid /remove 2>&1 | Out-Null } catch {}
        try { & bcdedit /delete $newGuid 2>&1 | Out-Null } catch {}
    }
    $st = @{ state = "failed"; phase = "bcd-arming"; error = "fault-injection: simulated failure during BCD arming"; updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"); updatedBy = "setup-wootc" } | ConvertTo-Json -Compress
    Set-Content -Force -Path "$wootcDir\state.json" -Value $st -Encoding UTF8
    throw "fault-injection: simulated failure during BCD arming"
}

# Point to the shim (Microsoft-signed, Fedora build). Shim verifies
# grubx64.efi (Fedora-signed), which loads grub.cfg from EFI/fedora/.
$setPathOutput = & bcdedit /set $newGuid path "\EFI\fedora\shimx64.efi" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "bcdedit /set path exited with code ${LASTEXITCODE}: $setPathOutput"
}
Write-Host "[wootc] BCD path set to \EFI\fedora\shimx64.efi"

# One-time boot: boot the deployer on the very next restart only.
$setBootSeqOutput = & bcdedit /set "{fwbootmgr}" bootsequence $newGuid /addfirst 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "bcdedit /set bootsequence exited with code ${LASTEXITCODE}: $setBootSeqOutput"
}
Write-Host "[wootc] Set one-time bootsequence to $newGuid"

# ── Observable verification (#50): prove the BCD state is correct ──────
# Query the new entry and {fwbootmgr} to confirm the EFI path and that
# bootsequence contains the new GUID.
$verifyGuidOut = (& bcdedit /enum $newGuid 2>&1) | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "bcdedit /enum $newGuid exited with code ${LASTEXITCODE}: $verifyGuidOut"
}
if ($verifyGuidOut -notmatch 'path.*shimx64\.efi') {
    throw "Verification failed: new BCD entry does not point to shimx64.efi`n$verifyGuidOut"
}
Write-Host "[wootc] Verified: BCD entry path points to shimx64.efi"

$verifyFwbmOut = (& bcdedit /enum "{fwbootmgr}" 2>&1) | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "bcdedit /enum {fwbootmgr} exited with code ${LASTEXITCODE}: $verifyFwbmOut"
}
if ($verifyFwbmOut -notmatch [regex]::Escape($newGuid)) {
    throw "Verification failed: {fwbootmgr} bootsequence does not contain $newGuid`n$verifyFwbmOut"
}
Write-Host "[wootc] Verified: {fwbootmgr} bootsequence contains $newGuid"

Write-Host "[wootc] BCD configured and verified successfully."

# ── Step 9: Disable Windows Fast Startup ────────────────────────────────────
Write-Host "[wootc] Disabling Fast Startup..."
try {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" `
        -Name "HiberbootEnabled" -Value 0 -Force -Type DWord
    Write-Host "[wootc] Fast Startup disabled"
} catch {
    Write-Host "[wootc] Warning: could not disable Fast Startup"
}

if ($FaultInject -eq "pre-reboot") {
    Write-Host "[wootc] Injected fault at boundary: pre-reboot (simulating cancellation before reboot)"
    try { & bcdedit /deletevalue "{fwbootmgr}" bootsequence 2>&1 | Out-Null } catch {}
    if ($newGuid) {
        try { & bcdedit /set "{fwbootmgr}" displayorder $newGuid /remove 2>&1 | Out-Null } catch {}
        try { & bcdedit /delete $newGuid 2>&1 | Out-Null } catch {}
    }
    $st = @{ state = "staged"; phase = "cancelled"; error = "fault-injection: simulated cancellation before reboot"; updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"); updatedBy = "setup-wootc" } | ConvertTo-Json -Compress
    Set-Content -Force -Path "$wootcDir\state.json" -Value $st -Encoding UTF8
    throw "fault-injection: simulated cancellation before reboot"
}

$st = @{ state = "armed"; updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"); updatedBy = "setup-wootc" } | ConvertTo-Json -Compress
Set-Content -Force -Path "$wootcDir\state.json" -Value $st -Encoding UTF8

# ── Step 10: Print summary ──────────────────────────────────────────────────
Write-Host ""
Write-Host "=== wootc setup complete ==="
Write-Host "  Image:       $ImageRef"
Write-Host "  Hostname:    $Hostname"
Write-Host "  root.disk:   $diskPath ($DiskSizeGB GB)"
Write-Host "  Install dir: $installDir"
Write-Host ""
Write-Host 'Ready to reboot. The system will boot into the wootc deployer.'
Write-Host ""
