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
    [int]$DiskSizeGB = 10
)

$ErrorActionPreference = "Stop"
$wootcDir = "C:\wootc"
$installDir = "$wootcDir\install"
$disksDir = "$wootcDir\disks"

Write-Host "[wootc] Setting up wootc test environment..."

# ── Step 1: Create directory structure ──────────────────────────────────────
Write-Host "[wootc] Creating directories..."
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
New-Item -ItemType Directory -Force -Path $disksDir | Out-Null

# ── Step 2: Create root.disk (sparse file) ──────────────────────────────────
Write-Host "[wootc] Creating root.disk ($DiskSizeGB GB)..."
$diskPath = "$disksDir\root.disk"
$sizeBytes = [long]$DiskSizeGB * 1024 * 1024 * 1024

# Use Windows API for sparse file creation with pre-allocation
$fileStream = [System.IO.File]::Open($diskPath,
    [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::None)

try {
    $fileStream.SetLength($sizeBytes)
    # Pre-allocate contiguous clusters (requires admin — we are admin)
    $fileStream.Flush()
} finally {
    $fileStream.Close()
}

# Try SetFileValidData for contiguous pre-allocation
try {
    $Kernel32 = Add-Type -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetFileValidData(IntPtr hFile, long ValidDataLength);
"@ -Name "Kernel32" -Namespace "Win32" -PassThru

    $fs = [System.IO.File]::Open($diskPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None)
    $Kernel32::SetFileValidData($fs.SafeFileHandle.DangerousGetHandle(), $sizeBytes)
    $fs.Close()
    Write-Host "[wootc] root.disk: contiguous pre-allocation successful"
} catch {
    Write-Host "[wootc] root.disk: contiguous pre-allocation failed (disk may be fragmented). Continuing..."
}

Write-Host "[wootc] root.disk created: $diskPath ($DiskSizeGB GB)"

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

# Try Samba share
# Strategy 1: Check dockur/windows Samba share
# dockur/windows mounts /shared as \\host.lan\Data
# We mount our wootc-files at /shared in the container

$sharePaths = @(
    "\\host.lan\Data",
    "\\10.0.2.2\Data"
)

foreach ($share in $sharePaths) {
    Write-Host "[wootc] Trying Samba share: $share"
    # Try to list the share to verify access
    $result = net use $share 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[wootc] Share $share not accessible, trying next..."
        continue
    }
    if (Test-Path "$share\vmlinuz") {
        Write-Host "[wootc] Found deployer files at $share"
        $deployerVmlinuz = "$share\vmlinuz"
        $deployerInitramfs = "$share\initramfs.img"
        $grubDir = "$share\grub"
        break
    }
}

if (-not $deployerVmlinuz) {
    Write-Error "Could not find deployer files via Samba share"
    exit 1
}

# Copy deployer files
Write-Host "[wootc] Copying deployer kernel..."
Copy-Item $deployerVmlinuz "$installDir\vmlinuz" -Force

Write-Host "[wootc] Copying deployer initramfs..."
Copy-Item $deployerInitramfs "$installDir\initramfs.img" -Force

# ── Step 4: Copy GRUB files ─────────────────────────────────────────────────
if ($grubDir) {
    # GRUB cfg files from the wootc repo
    Copy-Item "$grubDir\*" "$installDir\" -Force -ErrorAction SilentlyContinue

    # Copy grubx64.efi from share if available (needed for BCD firmware entry)
    $grubEfiSrc = "$share\grubx64.efi"
    if (Test-Path $grubEfiSrc) {
        Copy-Item $grubEfiSrc "$installDir\grubx64.efi" -Force
        Write-Host "[wootc] Copied grubx64.efi from share"
    } else {
        Write-Host "[wootc] WARNING: grubx64.efi not found on share at $grubEfiSrc"
        Write-Host "[wootc]   BCD firmware entry will be created but may not boot without it."
    }
}

# ── Step 5: Write GRUB install config ───────────────────────────────────────
# This is the first-boot GRUB menu that boots the deployer
$grubInstallCfg = @"
# wootc first-boot installer menu
set default=0
set timeout=5

menuentry "Install wootc (automatic)" {
    linux /wootc/install/vmlinuz wootc.image=$ImageRef wootc.hostname=$Hostname quiet
    initrd /wootc/install/initramfs.img
}

menuentry "Install wootc (debug)" {
    linux /wootc/install/vmlinuz wootc.image=$ImageRef wootc.hostname=$Hostname wootc.debug
    initrd /wootc/install/initramfs.img
}
"@

Set-Content -Path "$installDir\grub.install.cfg" -Value $grubInstallCfg -Encoding ASCII
Write-Host "[wootc] Wrote grub.install.cfg"

# ── Step 6: Write wubildr.cfg ───────────────────────────────────────────────
# Main GRUB config — dual-mode: boot installed OS or fall to installer
$wubildrCfg = @'
set show_panic_message=true

if search -s -f -n /wootc/disks/root.disk; then
    if loopback loopw0 /wootc/disks/root.disk; then
        set root=(loopw0)
        if [ -e /boot/grub2/grub.cfg ]; then
            set prefix=($root)'/boot/grub2'
            if configfile /boot/grub2/grub.cfg; then
                set show_panic_message=false
            fi
        fi
    fi
fi

if [ ${show_panic_message} = true ]; then
    if search -s -f -n /wootc/install/grub.install.cfg; then
        if configfile /wootc/install/grub.install.cfg; then
            set show_panic_message=false
        fi
    fi
fi

if [ ${show_panic_message} = true ]; then
    echo "wootc: Could not boot — installation may be incomplete."
    echo "Please reboot into Windows and check C:\wootc\"
fi
'@

Set-Content -Path "$installDir\wubildr.cfg" -Value $wubildrCfg -Encoding ASCII
Write-Host "[wootc] Wrote wubildr.cfg"

# ── Step 7: Install GRUB2 to ESP and configure BCD ──────────────────────────
Write-Host "[wootc] Setting up Windows Boot Manager entry..."

# Mount ESP (EFI System Partition)
$espMount = "$wootcDir\esp"
New-Item -ItemType Directory -Force -Path $espMount | Out-Null

# Find and mount the ESP
$espVolume = Get-Volume | Where-Object { $_.FileSystemType -eq "FAT32" -and $_.Size -lt 1GB }
if (-not $espVolume) {
    # Try to find by partition type
    $espPart = Get-Partition | Where-Object { $_.Type -eq "System" -or $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" }
    if ($espPart) {
        $espLetter = if ($espPart.DriveLetter) { $espPart.DriveLetter } else { "S" }
        if (-not $espPart.DriveLetter) {
            $espPart | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
        }
        $espPath = "$($espPart.DriveLetter):\"
    }
} else {
    $espPath = "$($espVolume.DriveLetter):\"
}

if (-not $espPath) {
    Write-Host "[wootc] Could not find ESP — using C: as fallback (non-UEFI or test env)"
    $espPath = "C:\"
}

# Create wootc GRUB directory on ESP
$wootcEfiDir = "$espPath\EFI\wootc\wubildr"
New-Item -ItemType Directory -Force -Path $wootcEfiDir | Out-Null

# Copy GRUB EFI binary (in a real install we'd use shim + grubx64.efi;
# for testing we use the QEMU VM's existing GRUB or chainload differently)
# For now, we rely on the existing Windows Boot Manager chainload via BCD

# Copy GRUB config files to ESP
Copy-Item "$installDir\wubildr.cfg" "$wootcEfiDir\" -Force

Write-Host "[wootc] GRUB files installed to $wootcEfiDir"

# ── Step 8: Configure BCD ───────────────────────────────────────────────────
# Add a UEFI firmware application boot entry pointing to grubx64.efi on the ESP.
# bcdedit /create outputs: "The entry {guid} was successfully created."
# We parse that GUID, then configure device/path/description and set boot order.

Write-Host "[wootc] Configuring BCD..."

# Resolve ESP drive letter (needed for the bcdedit device parameter)
$espDrive = $null
if ($espPath -match '^([A-Za-z]):\\') {
    $espDrive = $Matches[1]
}
if (-not $espDrive) {
    Write-Host "[wootc] WARNING: Could not determine ESP drive letter — using C as fallback"
    $espDrive = "C"
}

# Copy grubx64.efi to ESP
$grubEfiDest = "${espPath}EFI\wootc\grubx64.efi"
if (Test-Path "$installDir\grubx64.efi") {
    Copy-Item "$installDir\grubx64.efi" $grubEfiDest -Force
    Write-Host "[wootc] Copied grubx64.efi to $grubEfiDest"
} else {
    Write-Host "[wootc] WARNING: grubx64.efi not in $installDir — ESP entry will point to a missing file."
    Write-Host "[wootc]   Ensure grubx64.efi is present on the Samba share (wootc-files/grubx64.efi)."
}

# Create a new firmware application BCD entry
$bcdCreateOutput = (& bcdedit /create /d "wootc Deployer" /application firmware 2>&1) | Out-String
Write-Host "[wootc] bcdedit create: $bcdCreateOutput"

# Parse the GUID from output like:
#   The entry {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx} was successfully created.
if ($bcdCreateOutput -match '\{([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\}') {
    $newGuid = "{$($Matches[1])}"
    Write-Host "[wootc] New BCD entry GUID: $newGuid"

    # Set the EFI path (must use backslashes, relative to ESP root)
    $efiRelPath = "\EFI\wootc\grubx64.efi"
    & bcdedit /set $newGuid path $efiRelPath
    Write-Host "[wootc] BCD path set to $efiRelPath"

    # Set the device to the ESP partition
    # 'partition=<letter>:' targets the partition by its assigned drive letter
    & bcdedit /set $newGuid device "partition=${espDrive}:"
    Write-Host "[wootc] BCD device set to partition=${espDrive}:"

    # Prepend to fwbootmgr display order (makes it visible in UEFI menu)
    & bcdedit /set "{fwbootmgr}" displayorder $newGuid /addfirst
    Write-Host "[wootc] Added $newGuid as first in fwbootmgr displayorder"

    # One-time boot: boot the deployer on the very next restart only
    & bcdedit /set "{fwbootmgr}" bootsequence $newGuid /addfirst
    Write-Host "[wootc] Set one-time bootsequence to $newGuid"

    Write-Host "[wootc] BCD configured successfully."
    Write-Host "[wootc]   Entry: $newGuid"
    Write-Host "[wootc]   Boots: ${espDrive}:$efiRelPath"
    Write-Host "[wootc]   One-shot: yes (bootsequence)"
} else {
    Write-Host "[wootc] ERROR: Could not parse GUID from bcdedit output:"
    Write-Host $bcdCreateOutput
    Write-Host "[wootc] BCD NOT configured — reboot will go to Windows, not deployer."
    # Non-fatal: setup can still succeed for debugging other steps
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
Write-Host "Ready to reboot. The system will boot into the wootc deployer."
Write-Host ""
