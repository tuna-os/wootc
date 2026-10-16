$clock = [System.Diagnostics.Stopwatch]::StartNew()
$stage = 'load-cim-assemblies'
[Console]::Error.WriteLine("storage-phase|$stage")
[Console]::Error.WriteLine("storage-cost|$stage|$($clock.ElapsedMilliseconds)")
try {
$WarningPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$PSModuleAutoLoadingPreference = 'None'
foreach ($assemblyName in @('Microsoft.Management.Infrastructure', 'Microsoft.Management.Infrastructure.CimCmdlets')) {
    $assemblyPath = "$env:windir\Microsoft.NET\assembly\GAC_MSIL\$assemblyName\v4.0_1.0.0.0__31bf3856ad364e35\$assemblyName.dll"
    $assembly = [System.Reflection.Assembly]::LoadFrom($assemblyPath)
    $expectedIdentity = "$assemblyName, Version=1.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35"
    if ($assembly.FullName -ne $expectedIdentity -or -not [string]::Equals($assembly.Location, $assemblyPath, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'CIM assembly binding refused' }
}
$stage = 'import-utility'
[Console]::Error.WriteLine("storage-phase|$stage")
[Console]::Error.WriteLine("storage-cost|$stage|$($clock.ElapsedMilliseconds)")
Import-Module -Name "$PSHOME\Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1" -ErrorAction Stop
$stage = 'import-cim'
[Console]::Error.WriteLine("storage-phase|$stage")
[Console]::Error.WriteLine("storage-cost|$stage|$($clock.ElapsedMilliseconds)")
Import-Module -Name "$PSHOME\Modules\CimCmdlets\CimCmdlets.psd1" -ErrorAction Stop
$stage = 'import-storage'
[Console]::Error.WriteLine("storage-phase|$stage")
[Console]::Error.WriteLine("storage-cost|$stage|$($clock.ElapsedMilliseconds)")
Import-Module -Name "$PSHOME\Modules\Storage\Storage.psd1" -ErrorAction Stop
$stage = 'import-bitlocker'
[Console]::Error.WriteLine("storage-phase|$stage")
[Console]::Error.WriteLine("storage-cost|$stage|$($clock.ElapsedMilliseconds)")
Import-Module -Name "$PSHOME\Modules\BitLocker\BitLocker.psd1" -ErrorAction Stop
$ErrorActionPreference = 'Stop'
$nonce = [string]$env:WOOTC_NATIVE_STORAGE_SESSION
$paired = -not [string]::IsNullOrEmpty($nonce)
if ($paired -and $nonce -cnotmatch '^[0-9a-f]{32}$') { throw 'Storage session refused' }
$count = 1
if ($paired) { $count = 2 }
for ($sequence = 1; $sequence -le $count; $sequence++) {
    if ($paired) {
        $request = [Console]::In.ReadLine()
        $expected = "$nonce|$sequence"
        if ($request -cne $expected) { throw 'Storage snapshot request refused' }
    }
$rows = @()
$stage = 'read-volumes'
[Console]::Error.WriteLine("storage-phase|$stage")
[Console]::Error.WriteLine("storage-cost|$stage|$($clock.ElapsedMilliseconds)")
$volumes = @(Storage\Get-Volume -ErrorAction Stop | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystem -eq 'NTFS' })
foreach ($volume in $volumes) {
    $drive = [string]$volume.DriveLetter
    $stage = 'read-partition'
    [Console]::Error.WriteLine("storage-phase|$stage")
[Console]::Error.WriteLine("storage-cost|$stage|$($clock.ElapsedMilliseconds)")
    $parts = @(Storage\Get-Partition -DriveLetter $drive -ErrorAction Stop)
    if ($parts.Count -ne 1) { throw 'Storage partition observation refused' }
    $part = $parts[0]
    $stage = 'read-disk'
    [Console]::Error.WriteLine("storage-phase|$stage")
[Console]::Error.WriteLine("storage-cost|$stage|$($clock.ElapsedMilliseconds)")
    $disks = @(Storage\Get-Disk -Number $part.DiskNumber -ErrorAction Stop)
    if ($disks.Count -ne 1) { throw 'Storage disk observation refused' }
    $disk = $disks[0]
    if ($disk.PartitionStyle -ne 'GPT' -or $disk.IsOffline -or $disk.IsReadOnly -or $part.IsReadOnly -or $part.IsHidden -or $part.GptType -ne '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}') { continue }
    $mount = "$drive`:"
    $stage = 'read-protection'
    [Console]::Error.WriteLine("storage-phase|$stage")
[Console]::Error.WriteLine("storage-cost|$stage|$($clock.ElapsedMilliseconds)")
    $protection = @(BitLocker\Get-BitLockerVolume -MountPoint $mount -ErrorAction Stop)
    if ($protection.Count -ne 1) { throw 'Storage protection observation refused' }
    $state = $protection[0]
    if ($null -eq $state.EncryptionPercentage -or $null -eq $state.VolumeStatus -or $null -eq $state.ProtectionStatus) { throw 'Storage protection properties absent' }
    $rows += [pscustomobject]@{ driveLetter=$drive; diskGuid=[string]$disk.Guid; partitionGuid=[string]$part.Guid; volumeStatus=[string]$state.VolumeStatus; protectionStatus=[string]$state.ProtectionStatus; encryptionPercentage=[int]$state.EncryptionPercentage }
}
$stage = 'serialize'
[Console]::Error.WriteLine("storage-phase|$stage")
[Console]::Error.WriteLine("storage-cost|$stage|$($clock.ElapsedMilliseconds)")
if ($paired) {
    $frame = [pscustomobject]@{ schemaVersion=1; nonce=$nonce; sequence=$sequence; pid=$PID; rows=@($rows) }
    $json = Microsoft.PowerShell.Utility\ConvertTo-Json -InputObject $frame -Compress -Depth 4
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
} else {
    Microsoft.PowerShell.Utility\ConvertTo-Json -InputObject @($rows) -Compress -Depth 3
}
}
} catch {
    $exception = $_.Exception
    $category = [int]$_.CategoryInfo.Category
    $loader = 'unclassified'
    $dependency = 'unclassified'
    switch ([string]$_.CategoryInfo.TargetName) {
        'New-Object' { $dependency = 'new-object' }
        'New-Alias' { $dependency = 'new-alias' }
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
