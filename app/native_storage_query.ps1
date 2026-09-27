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
    $exception = $_.Exception
    $category = [int]$_.CategoryInfo.Category
    $loader = 'unclassified'
    $dependency = 'unclassified'
    switch ([string]$_.CategoryInfo.TargetName) {
        'New-Object' { $dependency = 'new-object' }
        'Import-LocalizedData' { $dependency = 'import-localized-data' }
        'Get-CimInstance' { $dependency = 'get-cim-instance' }
        'Add-Type' { $dependency = 'add-type' }
        'ConvertFrom-StringData' { $dependency = 'convert-from-string-data' }
        'Add-Member' { $dependency = 'add-member' }
        'Update-TypeData' { $dependency = 'update-type-data' }
        'Get-ChildItem' { $dependency = 'get-child-item' }
        'Join-Path' { $dependency = 'join-path' }
        'Split-Path' { $dependency = 'split-path' }
        'Test-Path' { $dependency = 'test-path' }
        'Select-Object' { $dependency = 'select-object' }
        'Where-Object' { $dependency = 'where-object' }
        'ForEach-Object' { $dependency = 'foreach-object' }
    }
    # Only fixed recognized loader identifiers cross the boundary.
    $errorId = ([string]$_.FullyQualifiedErrorId).Split(',')[0]
    switch ($errorId) {
        'Modules_InvalidManifest' { $loader = 'invalid-manifest' }
        'Modules_ModuleNotFound' { $loader = 'module-not-found' }
        'Modules_ImportModuleError' { $loader = 'module-import' }
        'Modules_CannotLoadNestedModule' { $loader = 'nested-module' }
        'ErrorsUpdatingTypes' { $loader = 'type-update' }
        'FormatXmlUpdateException' { $loader = 'format-update' }
        'TypesXmlUpdateException' { $loader = 'type-xml-update' }
        'CommandNotFoundException' { $loader = 'command-not-found' }
        'Modules_InvalidRootModule' { $loader = 'invalid-root-module' }
        'Modules_InvalidRequiredAssembly' { $loader = 'invalid-required-assembly' }
    }
    # Inspect only typed exceptions. Never print messages, paths, IDs or objects.
    for ($depth = 0; $depth -lt 4 -and $null -ne $exception; $depth++) {
        $type = 'other'
        switch ($exception.GetType().FullName) {
            'System.Management.Automation.CommandNotFoundException' { $type = 'command-not-found' }
            'System.Management.Automation.RuntimeException' { $type = 'runtime' }
            'System.Management.Automation.ParentContainsErrorRecordException' { $type = 'parent-error-record' }
            'System.Management.Automation.CmdletInvocationException' { $type = 'cmdlet-invocation' }
            'System.Management.Automation.PSArgumentException' { $type = 'ps-argument' }
            'System.Management.Automation.PSSnapInException' { $type = 'ps-snapin' }
            'System.Management.Automation.PSNotSupportedException' { $type = 'ps-not-supported' }
            'System.Management.Automation.PSInvalidCastException' { $type = 'ps-invalid-cast' }
            'System.Management.Automation.TypesXmlUpdateException' { $type = 'types-xml-update' }
            'System.Management.Automation.FormatXmlUpdateException' { $type = 'format-xml-update' }
            'System.Management.Automation.ParameterBindingException' { $type = 'parameter-binding' }
            'System.Management.Automation.ActionPreferenceStopException' { $type = 'action-preference' }
            'System.UnauthorizedAccessException' { $type = 'access' }
            'System.Runtime.InteropServices.COMException' { $type = 'com' }
            'System.IO.FileNotFoundException' { $type = 'file-not-found' }
            'System.IO.FileLoadException' { $type = 'file-load' }
            'System.TypeLoadException' { $type = 'type-load' }
            'System.InvalidOperationException' { $type = 'invalid-operation' }
            'System.Management.Automation.PSInvalidOperationException' { $type = 'ps-invalid-operation' }
        }
        $hresult = [int]$exception.HResult
        [Console]::Error.WriteLine("native-storage-failure stage=$stage depth=$depth type=$type hresult=$hresult category=$category loader=$loader dependency=$dependency")
        $next = $exception.InnerException
        if ($null -eq $next -and $exception -is [System.Management.Automation.ActionPreferenceStopException]) {
            $next = $exception.ErrorRecord.Exception
        }
        if ([object]::ReferenceEquals($exception, $next)) { break }
        $exception = $next
    }
    exit 1
}
