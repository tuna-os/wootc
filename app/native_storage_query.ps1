$PSModuleAutoLoadingPreference = 'None'
Import-Module -Name "$PSHOME\Modules\Storage\Storage.psd1" -ErrorAction Stop
Import-Module -Name "$PSHOME\Modules\BitLocker\BitLocker.psd1" -ErrorAction Stop
Import-Module -Name "$PSHOME\Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1" -ErrorAction Stop
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$rows = @()
$volumes = @(Storage\Get-Volume -ErrorAction Stop | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystem -eq 'NTFS' })
foreach ($volume in $volumes) {
    $drive = [string]$volume.DriveLetter
    $parts = @(Storage\Get-Partition -DriveLetter $drive -ErrorAction Stop)
    if ($parts.Count -ne 1) { throw 'Storage partition observation refused' }
    $part = $parts[0]
    $disks = @(Storage\Get-Disk -Number $part.DiskNumber -ErrorAction Stop)
    if ($disks.Count -ne 1) { throw 'Storage disk observation refused' }
    $disk = $disks[0]
    if ($disk.PartitionStyle -ne 'GPT' -or $disk.IsOffline -or $disk.IsReadOnly -or $part.IsReadOnly -or $part.IsHidden -or $part.GptType -ne '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}') { continue }
    $mount = "$drive`:"
    $protection = @(BitLocker\Get-BitLockerVolume -MountPoint $mount -ErrorAction Stop)
    if ($protection.Count -ne 1) { throw 'Storage protection observation refused' }
    $state = $protection[0]
    if ($null -eq $state.EncryptionPercentage -or $null -eq $state.VolumeStatus -or $null -eq $state.ProtectionStatus) { throw 'Storage protection properties absent' }
    $rows += [pscustomobject]@{ driveLetter=$drive; diskGuid=[string]$disk.Guid; partitionGuid=[string]$part.Guid; volumeStatus=[string]$state.VolumeStatus; protectionStatus=[string]$state.ProtectionStatus; encryptionPercentage=[int]$state.EncryptionPercentage }
}
Microsoft.PowerShell.Utility\ConvertTo-Json -InputObject @($rows) -Compress -Depth 3
