# Embedded production policy. Every observation is read-only until explicit removal.
function Convert-WootcPartitionGuid {
    param($Value)
    if ([string]$Value -notmatch '^\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}?$') { throw 'Partition identity is missing or invalid' }
    $guid = ([guid]$Value).ToString('D').ToLowerInvariant()
    if ($guid -eq '00000000-0000-0000-0000-000000000000') { throw 'Partition identity is empty' }
    return $guid
}

function Get-WootcPartitionProductFiles {
    # Exact paths only. Unknown cache, Wi-Fi, application or personal files block
    # partition removal; an installer directory never owns all its descendants.
    @(
        'wootc/disks/root.disk', 'wootc/disks/root.vhdx', 'wootc/state.json',
        'wootc/channel.txt', 'wootc/brand.json', 'wootc/brand.css', 'wootc/images.json',
        'wootc/known-folders.json', 'wootc/cloud-drives.json', 'wootc/wootc.exe',
        'wootc/e2e-drive.json', 'wootc/e2e-drive-state.json',
        'wootc/install/vault.json', 'wootc/install/prior-power.txt', 'wootc/install/bcd-before.bak',
        'wootc/install/bcd-guid.txt', 'wootc/install/wootc.exe', 'wootc/install/armed.json',
        'wootc/install/deployer-started.json', 'wootc/install/recovery-verdict.json',
        'wootc/install/installation.json', 'wootc/install/installed-linux-boot.json',
        'wootc/install/installed-linux-boot.complete', 'wootc/install/bitlocker-key.txt',
        'wootc/install/SHA256SUMS', 'wootc/install/SHA256SUMS.sig',
        'wootc/install/deployer-vmlinuz', 'wootc/install/deployer-initramfs.img',
        'wootc/install/shimx64.efi', 'wootc/install/grubx64.efi', 'wootc/install/mmx64.efi',
        'wootc/install/systemd-bootx64.efi', 'wootc/install/shim-authorities.json',
        'wootc/install/grub.install.cfg', 'wootc/install/wubildr.cfg', 'wootc/install/wubildr-bootstrap.cfg',
        'wootc/install/programs.json', 'wootc/install/slurp/slurp.json',
        'wootc/install/slurp/wallpaper.jpg', 'wootc/install/slurp/wallpaper.jpeg',
        'wootc/install/slurp/wallpaper.png', 'wootc/install/slurp/wallpaper.bmp',
        'wootc/install/slurp/session/exports.json', 'wootc/logs/deployer.log',
        'wootc/logs/deployer-last-journal.log',
        'system volume information/mountpointmanagerremotedatabase',
        'system volume information/wpsettings.dat', '$recycle.bin/desktop.ini'
    )
}

function Assert-WootcPartitionContents {
    param([string]$Drive, [switch]$InstallerTreeOnly, [string]$Root)
    if (-not $Root) { $Root = "${Drive}:/" }
    $root = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $root = "$root$([IO.Path]::DirectorySeparatorChar)"
    $files = @(Get-WootcPartitionProductFiles)
    $directories = @('wootc', '$recycle.bin', 'system volume information')
    foreach ($file in $files) {
        $parts = $file.Split('/')
        for ($i = 1; $i -lt $parts.Count; $i++) {
            $directories += ($parts[0..($i - 1)] -join '/')
        }
    }
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    if ($InstallerTreeOnly) {
        $installerRoot = Join-Path $root 'wootc'
        $rootItem = Get-Item -LiteralPath $installerRoot -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or $null -eq $rootItem.Attributes -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Installer root is not a regular directory' }
        $queue.Enqueue($installerRoot)
    } else { $queue.Enqueue($root) }
    $seen = @{}
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        # No -Recurse: inspect/reject junctions before ever descending into them.
        $items = @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop)
        foreach ($item in $items) {
            $full = [string]$item.FullName
            if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Volume enumeration returned an out-of-volume path' }
            $relative = $full.Substring($root.Length).Replace('\', '/').ToLowerInvariant()
            if ($relative -match '(^|/)\.\.?(/|$)' -or $seen.ContainsKey($relative)) { throw 'Volume enumeration returned ambiguous paths' }
            $seen[$relative] = $true
            if ($null -eq $item.Attributes -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Volume contains an unsafe reparse point' }
            if ($null -eq $item.PSIsContainer) { throw 'Volume enumeration returned an unknown object type' }
            if ($item.PSIsContainer) {
                if ($relative -notin $directories) { throw "Partition contains an unattributed directory: $relative" }
                $queue.Enqueue($full)
            } elseif ($relative -notin $files) {
                throw "Partition contains an unattributed file: $relative"
            }
        }
    }
}

function Get-WootcPartitionRemovalBinding {
    param([string]$Drive, $Receipt, [switch]$SkipContents)
    $ErrorActionPreference = 'Stop'
    if ($Drive -notmatch '^[A-Z]$' -or $Drive -eq 'C') { throw 'Refusing to remove the Windows drive or an invalid drive' }
    if ($null -eq $Receipt -or $Receipt.schemaVersion -ne 1) { throw 'A valid persistent creation receipt is required' }
    $partitionGuid = Convert-WootcPartitionGuid $Receipt.partitionGuid
    $diskGuid = Convert-WootcPartitionGuid $Receipt.diskGuid
    $sourceGuid = Convert-WootcPartitionGuid $Receipt.sourceCPartitionGuid
    $sourceDiskGuid = Convert-WootcPartitionGuid $Receipt.sourceCDiskGuid
    if ($partitionGuid -eq $sourceGuid -or $diskGuid -ne $sourceDiskGuid) { throw 'Creation receipt does not bind a dedicated partition on the Windows disk' }
    $volumes = @(Get-Volume -DriveLetter $Drive -ErrorAction Stop)
    $partitions = @(Get-Partition -DriveLetter $Drive -ErrorAction Stop)
    $sources = @(Get-Partition -DriveLetter C -ErrorAction Stop)
    if ($volumes.Count -ne 1 -or $partitions.Count -ne 1 -or $sources.Count -ne 1) { throw 'Partition or Windows source is missing or ambiguous' }
    $volume = $volumes[0]; $partition = $partitions[0]; $source = $sources[0]
    if ($volume.FileSystemLabel -ne 'wootc-data' -or $volume.FileSystemType -ne 'NTFS') { throw 'Dedicated volume label or NTFS identity changed' }
    if ($partition.GptType -ne '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -or $partition.Type -ne 'Basic' -or $partition.IsBoot -ne $false -or $partition.IsSystem -ne $false -or $partition.IsHidden -ne $false -or $partition.IsOffline -ne $false -or $partition.IsReadOnly -ne $false) { throw 'Refusing a system, EFI, hidden or unsupported partition' }
    if ($source.IsBoot -ne $true -or (Convert-WootcPartitionGuid $source.Guid) -ne $sourceGuid) { throw 'Windows source partition identity changed' }
    if ((Convert-WootcPartitionGuid $partition.Guid) -ne $partitionGuid -or $partition.DiskNumber -ne $source.DiskNumber) { throw 'Target partition identity or Windows disk changed' }
    if ($null -eq $Receipt.sizeBytes -or [uint64]$Receipt.sizeBytes -eq 0 -or $partition.Size -ne [uint64]$Receipt.sizeBytes) { throw 'Created partition size changed or is unknown' }
    $disks = @(Get-Disk -Number $partition.DiskNumber -ErrorAction Stop)
    if ($disks.Count -ne 1 -or $disks[0].PartitionStyle -ne 'GPT' -or $disks[0].Number -ne $source.DiskNumber -or (Convert-WootcPartitionGuid $disks[0].Guid) -ne $diskGuid) { throw 'Physical GPT disk identity changed' }
    if (-not $SkipContents) { Assert-WootcPartitionContents -Drive $Drive }
    [pscustomobject]@{Partition=$partition; Source=$source; Disk=$disks[0]; Volume=$volume}
}

function New-WootcPartitionCreationReceipt {
    param($CreatedPartition, $SourcePartition, [string]$SourceDiskGuid)
    $ErrorActionPreference = 'Stop'
    $disk = @(Get-Disk -Number $CreatedPartition.DiskNumber -ErrorAction Stop)
    if ($disk.Count -ne 1 -or $disk[0].PartitionStyle -ne 'GPT' -or $CreatedPartition.DiskNumber -ne $SourcePartition.DiskNumber) { throw 'Created partition is not on the original Windows GPT disk' }
    $receipt = [pscustomobject]@{
        schemaVersion=1
        partitionGuid=(Convert-WootcPartitionGuid $CreatedPartition.Guid)
        diskGuid=(Convert-WootcPartitionGuid $disk[0].Guid)
        sourceCPartitionGuid=(Convert-WootcPartitionGuid $SourcePartition.Guid)
        sourceCDiskGuid=(Convert-WootcPartitionGuid $SourceDiskGuid)
        sizeBytes=[uint64]$CreatedPartition.Size
        createdAt=(Get-Date).ToUniversalTime().ToString('o')
    }
    $drive = [string]$CreatedPartition.DriveLetter
    Get-WootcPartitionRemovalBinding -Drive $drive -Receipt $receipt -SkipContents | Out-Null
    $receipt
}

function Get-WootcCreatedPartitionLocation {
    param($Receipt)
    $ErrorActionPreference = 'Stop'
    if ($null -eq $Receipt -or $Receipt.schemaVersion -ne 1) { throw 'A valid persistent creation receipt is required' }
    $targetGuid = Convert-WootcPartitionGuid $Receipt.partitionGuid
    $sourceGuid = Convert-WootcPartitionGuid $Receipt.sourceCPartitionGuid
    $diskGuid = Convert-WootcPartitionGuid $Receipt.sourceCDiskGuid
    if ($targetGuid -eq $sourceGuid -or (Convert-WootcPartitionGuid $Receipt.diskGuid) -ne $diskGuid) { throw 'Receipt does not bind the original Windows disk' }
    $sources = @(Get-Partition -DriveLetter C -ErrorAction Stop)
    if ($sources.Count -ne 1 -or $sources[0].IsBoot -ne $true -or (Convert-WootcPartitionGuid $sources[0].Guid) -ne $sourceGuid) { throw 'Original Windows source partition is missing or changed' }
    $disks = @(Get-Disk -Number $sources[0].DiskNumber -ErrorAction Stop)
    if ($disks.Count -ne 1 -or $disks[0].PartitionStyle -ne 'GPT' -or $disks[0].Number -ne $sources[0].DiskNumber -or (Convert-WootcPartitionGuid $disks[0].Guid) -ne $diskGuid) { throw 'Original Windows disk identity changed' }
    $partitions = @(Get-Partition -DiskNumber $sources[0].DiskNumber -ErrorAction Stop)
    $observedSources = @($partitions | Where-Object { (Convert-WootcPartitionGuid $_.Guid) -eq $sourceGuid })
    if ($observedSources.Count -ne 1) { throw 'Full disk enumeration did not positively observe the original Windows partition' }
    $matches = @($partitions | Where-Object { (Convert-WootcPartitionGuid $_.Guid) -eq $targetGuid })
    if ($matches.Count -gt 1) { throw 'Created partition identity is ambiguous' }
    $target = $null
    if ($matches.Count -eq 1) { $target = $matches[0] }
    [pscustomobject]@{Partition=$target; Source=$sources[0]; Disk=$disks[0]}
}

function Remove-WootcCreatedPartition {
    param([string]$Drive, $Receipt, [switch]$ExplicitRemoval, [switch]$AllowExtensionRetry, [switch]$DeferExtension)
    $ErrorActionPreference = 'Stop'
    if (-not $ExplicitRemoval) { throw 'Removing Linux data requires the explicit partition-removal choice' }
    $location = Get-WootcCreatedPartitionLocation -Receipt $Receipt
    if ($null -eq $location.Partition -and -not $AllowExtensionRetry) { throw 'Created partition is absent without a recorded removal attempt' }
    if ($null -ne $location.Partition) {
        if ([string]$location.Partition.DriveLetter -ne $Drive) { throw 'Created partition drive letter changed' }
        # Full fresh enumeration and identity checks immediately precede the
        # destructive call, which consumes the actual verified object.
        $binding = Get-WootcPartitionRemovalBinding -Drive $Drive -Receipt $Receipt
        Remove-Partition -InputObject $binding.Partition -Confirm:$false -ErrorAction Stop
    }
    # A retained receipt also permits retrying extension after an earlier
    # verified deletion. Never remove a replacement occupying the old letter.
    $remaining = Get-WootcCreatedPartitionLocation -Receipt $Receipt
    if ($null -ne $remaining.Partition) { throw 'Partition removal was not observed' }
    if ($DeferExtension) { Write-Output 'partition-removal-observed'; return }
    $supported = Get-PartitionSupportedSize -InputObject $remaining.Source -ErrorAction Stop
    if ($null -eq $supported.SizeMax -or $supported.SizeMax -lt $remaining.Source.Size) { throw 'Windows extension size is invalid' }
    Resize-Partition -InputObject $remaining.Source -Size $supported.SizeMax -ErrorAction Stop
    $observed = Get-WootcCreatedPartitionLocation -Receipt $Receipt
    if ($null -ne $observed.Partition -or $observed.Source.Size -ne $supported.SizeMax) { throw 'Windows partition extension was not observed' }
    Write-Output 'partition-removal-and-extension-verified'
}

function Remove-WootcInstallerFiles {
    param([string]$Root)
    $ErrorActionPreference = 'Stop'
    Assert-WootcPartitionContents -Root $Root -InstallerTreeOnly
    $root = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $root = "$root$([IO.Path]::DirectorySeparatorChar)"
    $directories = @{}
    foreach ($relative in @(Get-WootcPartitionProductFiles)) {
        if (-not $relative.StartsWith('wootc/')) { continue }
        $path = Join-Path $root $relative
        $parent = [IO.Path]::GetDirectoryName($path)
        while ($parent -and $parent.TrimEnd('\', '/') -ne $root.TrimEnd('\', '/')) {
            $directories[$parent] = $true
            if (Test-Path -LiteralPath $parent -ErrorAction Stop) {
                $item = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
                if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Companion path became unsafe' }
            }
            $parent = [IO.Path]::GetDirectoryName($parent)
        }
        if (Test-Path -LiteralPath $path -ErrorAction Stop) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Companion file became unsafe' }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
    foreach ($directory in @($directories.Keys | Sort-Object Length -Descending)) {
        if (Test-Path -LiteralPath $directory -ErrorAction Stop) {
            # Nonrecursive deletion fails if any new or unknown file appeared.
            [IO.Directory]::Delete($directory, $false)
        }
    }
    Write-Output 'companion-cleanup-verified'
}
