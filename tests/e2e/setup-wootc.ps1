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
    # 25 GB minimum: fisherman redirects podman storage INTO the target disk
    # (.fisherman-scratch) and unpacks the image into the target's ostree repo,
    # so the loop file must hold extracted image (~10 GB for yellowfin:gnome)
    # + blob scratch + filesystem overhead. 10 GB ENOSPC'd during the pull.
    [int]$DiskSizeGB = 25,
    # Phase-2 bootloader the deployer installs: "grub2" (traditional ostree),
    # "systemd" (composefs-native), or "auto" (default) to let the DEPLOYER
    # detect it definitively from the image (grub in bootupd → grub2, else
    # systemd). Passed through as wootc.bootloader=.
    [ValidateSet("grub2", "systemd", "auto")]
    [string]$Bootloader = "auto",
    # composefs-backed images require systemd-boot; adds wootc.composefs=1.
    [switch]$ComposeFs,
    # In the E2E image, Dockur copies /oem to C:\OEM. Supplying this path
    # makes setup self-contained and avoids requiring SMB/WinRM to be ready.
    [string]$PayloadDir = ""
)

$ErrorActionPreference = "Stop"

# Extra deployer kargs for the bootloader/composefs axes of the test matrix.
# grub2 + no composefs reproduces the historical default exactly.
$WootcKargs = "wootc.bootloader=$Bootloader"
if ($ComposeFs) { $WootcKargs += " wootc.composefs=1" }
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
    $needBytes = ([int64]$DiskSizeGB + 6) * 1GB
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
Write-Host "[wootc] Creating root.disk ($DiskSizeGB GB sparse raw image)..."
$diskPath = "$disksDir\root.disk"
$sizeBytes = [int64]$DiskSizeGB * 1GB

# Create, mark sparse, then set the length. Order matters: marking sparse BEFORE
# setting the length is what keeps it from being physically allocated.
$fs = [System.IO.File]::Create($diskPath)
$fs.Close()
& fsutil.exe sparse setflag "$diskPath" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "fsutil could not mark $diskPath sparse (is the volume NTFS?)"
}
$fs = [System.IO.File]::Open($diskPath, 'Open', 'Write')
try   { $fs.SetLength($sizeBytes) }
finally { $fs.Close() }

if (-not (Test-Path $diskPath)) { throw "Failed to create raw image at $diskPath" }
$actual = (Get-Item $diskPath).Length
if ($actual -ne $sizeBytes) {
    throw "root.disk is $actual bytes, expected $sizeBytes"
}
$sparse = (& fsutil.exe sparse queryflag "$diskPath") -join ' '
Write-Host "[wootc] root.disk created: $actual bytes, $sparse"

Write-Host "[wootc] root.disk created: $diskPath ($DiskSizeGB GB dynamic VHDX)"

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

Set-Content -Path "$installDir\grub.install.cfg" -Value $grubInstallLines -Encoding ASCII
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

Set-Content -Path "$installDir\wubildr.cfg" -Value $wubildrLines -Encoding ASCII
Write-Host "[wootc] Wrote wubildr.cfg"

# ── Step 7: Install signed shim + GRUB to ESP ──────────────────────────────
# Under Secure Boot, unsigned EFI binaries are rejected. Use the Fedora-signed
# shim → GRUB chain. Deployer kernel+initramfs go on the FAT32 ESP so GRUB can
# load them (the signed GRUB cannot load unsigned ntfs.mod).
Write-Host "[wootc] Setting up Secure Boot chain on ESP..."

# Find the real EFI System Partition and assign a drive letter.
$espPart = Get-Partition |
    Where-Object { $_.Type -eq "System" -or $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" } |
    Select-Object -First 1

if (-not $espPart) {
    throw "Could not find the EFI System Partition; refusing to place EFI files on C:."
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

# Copy deployer kernel + initramfs to ESP (GRUB reads FAT32 but not NTFS).
if (Test-Path "$installDir\deployer-vmlinuz") {
    Copy-Item "$installDir\deployer-vmlinuz" "$espPath\EFI\wootc\deployer-vmlinuz" -Force
}
if (Test-Path "$installDir\deployer-initramfs.img") {
    Copy-Item "$installDir\deployer-initramfs.img" "$espPath\EFI\wootc\deployer-initramfs.img" -Force
}
Write-Host "[wootc] Deployer kernel + initramfs copied to ESP:EFI/wootc/"

# Write the deployer grub.cfg at the signed GRUB's embedded prefix.
$grubCfgLines = @(
    '# wootc deployer — one-shot Linux installation',
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
Set-Content -Path "$espPath\EFI\fedora\grub.cfg" -Value $grubCfgLines -Encoding ASCII
Write-Host "[wootc] Wrote deployer grub.cfg to ESP:EFI/fedora/grub.cfg"

# ── Step 8: Configure BCD ───────────────────────────────────────────────────
# Add a one-shot UEFI firmware entry pointing to the signed shim → GRUB chain.

Write-Host "[wootc] Configuring BCD..."

# Create a new BCD entry by cloning the Windows Boot Manager.
$bcdCreateOutput = (& bcdedit /copy "{bootmgr}" /d "wootc Deployer" 2>&1) | Out-String
Write-Host "[wootc] bcdedit copy: $bcdCreateOutput"

if ($bcdCreateOutput -match '\{([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\}') {
    $newGuid = "{$($Matches[1])}"
    Write-Host "[wootc] New BCD entry GUID: $newGuid"

    # Persist the GUID so the E2E runner can re-arm the one-shot for Phase 2.
    Set-Content -Path "$installDir\bcd-guid.txt" -Value $newGuid -Encoding ASCII

    # Point to the shim (Microsoft-signed, Fedora build). Shim verifies
    # grubx64.efi (Fedora-signed), which loads grub.cfg from EFI/fedora/.
    & bcdedit /set $newGuid path "\EFI\fedora\shimx64.efi"
    Write-Host "[wootc] BCD path set to \EFI\fedora\shimx64.efi"

    # One-time boot: boot the deployer on the very next restart only.
    & bcdedit /set "{fwbootmgr}" bootsequence $newGuid /addfirst
    Write-Host "[wootc] Set one-time bootsequence to $newGuid"

    Write-Host "[wootc] BCD configured successfully."
} else {
    Write-Host "[wootc] ERROR: Could not parse GUID from bcdedit output:"
    Write-Host $bcdCreateOutput
}

# ── Step 9: Disable Windows Fast Startup ────────────────────────────────────
Write-Host "[wootc] Disabling Fast Startup..."
try {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" `
        -Name "HiberbootEnabled" -Value 0 -Force -Type DWord
    Write-Host "[wootc] Fast Startup disabled"
} catch {
    Write-Host "[wootc] Warning: could not disable Fast Startup"
}

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
