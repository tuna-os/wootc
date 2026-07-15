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
    [int]$DiskSizeGB = 10,
    # In the E2E image, Dockur copies /oem to C:\OEM. Supplying this path
    # makes setup self-contained and avoids requiring SMB/WinRM to be ready.
    [string]$PayloadDir = ""
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
Write-Host ("[wootc] Creating root.disk (" + $DiskSizeGB + " GB)...")
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

Write-Host ("[wootc] root.disk created: " + $diskPath + " (" + $DiskSizeGB + " GB)")

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
    # GRUB cfg files from the wootc repo
    Copy-Item "$grubDir\*" $installDir -Force -ErrorAction SilentlyContinue

    # Copy wubildr.efi from share if available (custom GRUB core image with embedded config)
    $grubEfiSrc = "$payloadRoot\wubildr.efi"
    if (Test-Path $grubEfiSrc) {
        Copy-Item $grubEfiSrc "$installDir\wubildr.efi" -Force
        Write-Host "[wootc] Copied wubildr.efi from share"
    } else {
        Write-Host "[wootc] WARNING: wubildr.efi not found on share at $grubEfiSrc"
        Write-Host "[wootc]   BCD firmware entry will be created but may not boot without it."
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
    "    linux /wootc/install/deployer-vmlinuz wootc.image=$ImageRef wootc.hostname=$Hostname quiet"
    '    initrd /wootc/install/deployer-initramfs.img'
    '}'
    ''
    'menuentry "Install wootc (debug)" {'
    "    linux /wootc/install/deployer-vmlinuz wootc.image=$ImageRef wootc.hostname=$Hostname wootc.debug"
    '    initrd /wootc/install/deployer-initramfs.img'
    '}'
)

Set-Content -Path "$installDir\grub.install.cfg" -Value $grubInstallLines -Encoding ASCII
Write-Host "[wootc] Wrote grub.install.cfg"

# ── Step 6: Write wubildr.cfg ───────────────────────────────────────────────
# Main GRUB config — dual-mode: boot installed OS or fall to installer.
$wubildrLines = @(
    'set show_panic_message=true'
    ''
    'if search -s -f -n /wootc/disks/root.disk; then'
    '    if loopback loopw0 /wootc/disks/root.disk; then'
    '        if [ -e (loopw0,gpt2)/grub2/grub.cfg ]; then'
    '            set root=(loopw0,gpt2)'
    '            set prefix=($root)/grub2'
    '            if configfile /grub2/grub.cfg; then'
    '                set show_panic_message=false'
    '            fi'
    '        fi'
    '    fi'
    'fi'
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

# ── Step 7: Install GRUB2 to ESP and configure BCD ──────────────────────────
Write-Host "[wootc] Setting up Windows Boot Manager entry..."

# Find the real EFI System Partition and assign it a drive letter. `Get-Volume`
# reports the usual unlettered FAT32 ESP with an empty DriveLetter; constructing
# `:\` from that empty value used to make the EFI copy fail or fall back to C:.
$espPart = Get-Partition |
    Where-Object { $_.Type -eq "System" -or $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" } |
    Select-Object -First 1

if (-not $espPart) {
    throw "Could not find the EFI System Partition; refusing to place wubildr on C:."
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

# Avoid a double-quoted path ending in `\`: Windows PowerShell treats the
# final quote as unterminated in this form. Build the separator explicitly.
$espPath = "${espDrive}:" + [System.IO.Path]::DirectorySeparatorChar
Write-Host "[wootc] EFI System Partition mounted at $espPath"

# Create wootc GRUB directory on ESP
$wootcEfiDir = "$espPath\EFI\wootc\wubildr"
New-Item -ItemType Directory -Force -Path $wootcEfiDir | Out-Null

# Copy GRUB EFI binary (wubildr.efi — custom GRUB core image with embedded
# bootstrap config, ntfs + loopback modules).

# Copy GRUB config files to ESP
Copy-Item "$installDir\wubildr.cfg" $wootcEfiDir -Force

Write-Host "[wootc] GRUB files installed to $wootcEfiDir"

# ── Step 8: Configure BCD ───────────────────────────────────────────────────
# Add a UEFI firmware application boot entry pointing to wubildr.efi on the ESP.
# bcdedit /create outputs: "The entry {guid} was successfully created."
# We parse that GUID, then configure device/path/description and set boot order.

Write-Host "[wootc] Configuring BCD..."

# Copy wubildr.efi to ESP (custom GRUB with ntfs+loopback modules, embedded bootstrap config)
$grubEfiDest = "${espPath}EFI\wootc\wubildr.efi"
if (Test-Path "$installDir\wubildr.efi") {
    Copy-Item "$installDir\wubildr.efi" $grubEfiDest -Force
    Write-Host "[wootc] Copied wubildr.efi to $grubEfiDest"
} else {
    Write-Host "[wootc] WARNING: wubildr.efi not in $installDir — ESP entry will point to a missing file."
    Write-Host "[wootc]   Ensure wubildr.efi is present on the Samba share (wootc-files/wubildr.efi)."
}

# Create a new BCD entry by cloning the Windows Boot Manager.
# This inherits device/partition settings — we only need to set the path.
$bcdCreateOutput = (& bcdedit /copy "{bootmgr}" /d "wootc Deployer" 2>&1) | Out-String
Write-Host "[wootc] bcdedit copy: $bcdCreateOutput"

# Parse the GUID from output like:
#   The entry was successfully copied to {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}.
if ($bcdCreateOutput -match '\{([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\}') {
    $newGuid = "{$($Matches[1])}"
    Write-Host "[wootc] New BCD entry GUID: $newGuid"

    # The E2E runner needs this stable identifier to schedule the second,
    # explicit one-shot boot that exercises the installed Phase 2 Linux root.
    Set-Content -Path "$installDir\bcd-guid.txt" -Value $newGuid -Encoding ASCII

    # Set the EFI path (device is inherited from bootmgr — partition=E:)
    $efiRelPath = "\EFI\wootc\wubildr.efi"
    & bcdedit /set $newGuid path $efiRelPath
    Write-Host "[wootc] BCD path set to $efiRelPath"

    # One-time boot: boot the deployer on the very next restart only.
    # Do NOT add to displayorder — we only want a one-shot test, not a persistent entry.
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
Write-Host ("  root.disk:   " + $diskPath + " (" + $DiskSizeGB + " GB)")
Write-Host ("  Install dir: " + $installDir)
Write-Host ""
Write-Host 'Ready to reboot. The system will boot into the wootc deployer.'
Write-Host ""
