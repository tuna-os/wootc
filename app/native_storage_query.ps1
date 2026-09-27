$stage = 'import-storage'
try {
$PSModuleAutoLoadingPreference = 'None'
Import-Module -Name "$PSHOME\Modules\Storage\Storage.psd1" -ErrorAction Stop
$stage = 'import-bitlocker'
Import-Module -Name "$PSHOME\Modules\BitLocker\BitLocker.psd1" -ErrorAction Stop
$stage = 'import-utility'
Import-Module -Name "$PSHOME\Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1" -ErrorAction Stop
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$rows = @()
$stage = 'read-volumes'
$volumes = @(Storage\Get-Volume -ErrorAction Stop | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystem -eq 'NTFS' })
foreach ($volume in $volumes) {
    $drive = [string]$volume.DriveLetter
    $stage = 'read-partition'
    $parts = @(Storage\Get-Partition -DriveLetter $drive -ErrorAction Stop)
    if ($parts.Count -ne 1) { throw 'Storage partition observation refused' }
    $part = $parts[0]
    $stage = 'read-disk'
    $disks = @(Storage\Get-Disk -Number $part.DiskNumber -ErrorAction Stop)
    if ($disks.Count -ne 1) { throw 'Storage disk observation refused' }
    $disk = $disks[0]
    if ($disk.PartitionStyle -ne 'GPT' -or $disk.IsOffline -or $disk.IsReadOnly -or $part.IsReadOnly -or $part.IsHidden -or $part.GptType -ne '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}') { continue }
    $mount = "$drive`:"
    $stage = 'read-protection'
    $protection = @(BitLocker\Get-BitLockerVolume -MountPoint $mount -ErrorAction Stop)
    if ($protection.Count -ne 1) { throw 'Storage protection observation refused' }
    $state = $protection[0]
    if ($null -eq $state.EncryptionPercentage -or $null -eq $state.VolumeStatus -or $null -eq $state.ProtectionStatus) { throw 'Storage protection properties absent' }
    $rows += [pscustomobject]@{ driveLetter=$drive; diskGuid=[string]$disk.Guid; partitionGuid=[string]$part.Guid; volumeStatus=[string]$state.VolumeStatus; protectionStatus=[string]$state.ProtectionStatus; encryptionPercentage=[int]$state.EncryptionPercentage }
}
$stage = 'serialize'
Microsoft.PowerShell.Utility\ConvertTo-Json -InputObject @($rows) -Compress -Depth 3
} catch {
    $exception = $_.Exception.GetBaseException()
    $type = 'other'
    switch ($exception.GetType().FullName) {
        'System.Management.Automation.CommandNotFoundException' { $type = 'command-not-found' }
        'System.Management.Automation.RuntimeException' { $type = 'runtime' }
        'System.Management.Automation.ParameterBindingException' { $type = 'parameter-binding' }
        'System.Management.Automation.ActionPreferenceStopException' { $type = 'action-preference' }
        'System.UnauthorizedAccessException' { $type = 'access' }
        'System.Runtime.InteropServices.COMException' { $type = 'com' }
    }
    $hresult = [int]$exception.HResult
    $category = [int]$_.CategoryInfo.Category
    [Console]::Error.WriteLine("native-storage-failure stage=$stage type=$type hresult=$hresult category=$category")
    exit 1
}
