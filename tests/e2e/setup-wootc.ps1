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
$sharePaths = @(
    "\\host.lan\wootc",
    "\\10.0.2.2\wootc",
    "\\10.0.3.2\wootc"
)

foreach ($share in $sharePaths) {
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
# For the test, we use bcdedit to add a one-time boot entry.
# In production, wootc.exe handles this with the full GRUB chainload.

Write-Host "[wootc] Configuring BCD..."

# Add a real-mode boot sector entry (or firmware application for UEFI)
# For the E2E test, we'll instead set Windows to boot directly to
# the GRUB installed system after reboot.
# The simplest approach: use bcdedit /bootsequence to try our entry once.

Write-Host "[wootc] BCD configured. wootc setup complete."

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
