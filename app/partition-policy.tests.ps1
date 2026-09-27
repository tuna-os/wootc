param([string]$HelperPath = (Join-Path $PSScriptRoot 'partition-policy.ps1'))
$ErrorActionPreference='Stop'
. $HelperPath
function Reset-Fixture {
    $script:receipt=[pscustomobject]@{schemaVersion=1;partitionGuid='11111111-1111-1111-1111-111111111111';diskGuid='22222222-2222-2222-2222-222222222222';sourceCPartitionGuid='33333333-3333-3333-3333-333333333333';sourceCDiskGuid='22222222-2222-2222-2222-222222222222';sizeBytes=1000;createdAt='2026-09-27T00:00:00Z'}
    $script:target=[pscustomobject]@{Guid=$script:receipt.partitionGuid;DiskNumber=0;PartitionNumber=4;DriveLetter='F';GptType='{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}';Type='Basic';IsBoot=$false;IsSystem=$false;IsHidden=$false;IsOffline=$false;IsReadOnly=$false;Size=1000}
    $script:source=[pscustomobject]@{Guid=$script:receipt.sourceCPartitionGuid;DiskNumber=0;PartitionNumber=3;DriveLetter='C';IsBoot=$true;Size=2000}
    $script:disk=[pscustomobject]@{Guid=$script:receipt.diskGuid;Number=0;PartitionStyle='GPT'}
    $script:volume=[pscustomobject]@{FileSystemLabel='wootc-data';FileSystemType='NTFS';Size=1000}
    $script:removed=$false; $script:removeCalls=0; $script:resizeCalls=0
    $script:enumerationError=$false; $script:missingSource=$false; $script:duplicateTarget=$false
    $script:foreignRoot=$false; $script:foreignNested=$false; $script:reparse=$false
    $script:lieRemove=$false; $script:lieResize=$false; $script:failRemove=$false; $script:failResize=$false
    $script:missingEnumeratedSource=$false; $script:diskEnumerationError=$false
    $script:swapAtQuery=0; $script:targetQueries=0; $script:swapSourceAfterRemove=$false
}
function Get-Volume { param($DriveLetter,$ErrorAction) $script:volume }
function Get-Partition { param($DriveLetter,$DiskNumber,$ErrorAction)
    if ($DriveLetter -eq 'C') { if (-not $script:missingSource) { $script:source }; return }
    if ($DriveLetter -eq 'F') {
        $script:targetQueries++
        if ($script:swapAtQuery -eq $script:targetQueries) { $script:target.Guid='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
        if (-not $script:removed) { $script:target; if ($script:duplicateTarget) { $script:target } }; return
    }
    if ($script:diskEnumerationError) { throw 'Mock disk enumeration failure' }
    if (-not $script:missingEnumeratedSource) { $script:source }
    if (-not $script:removed) { $script:target }
}
function Get-Disk { param($Number,$ErrorAction) $script:disk }
function Get-ChildItem { param($LiteralPath,[switch]$Force,$ErrorAction)
    if ($ErrorAction -ne 'Stop') { throw 'Enumeration must be fail-closed' }
    if (-not $LiteralPath.StartsWith('F:\')) { Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $LiteralPath -Force -ErrorAction Stop; return }
    if ($script:enumerationError) { throw 'Mock enumeration error' }
    if ($LiteralPath -eq 'F:\') {
        if ($script:foreignRoot) { [pscustomobject]@{FullName='F:\photo.jpg';PSIsContainer=$false;Attributes=[IO.FileAttributes]::Normal} }
        $attributes=[IO.FileAttributes]::Directory
        if ($script:reparse) { $attributes=$attributes -bor [IO.FileAttributes]::ReparsePoint }
        [pscustomobject]@{FullName='F:\wootc';PSIsContainer=$true;Attributes=$attributes}
    } elseif ($LiteralPath -eq 'F:\wootc') {
        if ($script:foreignNested) { [pscustomobject]@{FullName='F:\wootc\photo.jpg';PSIsContainer=$false;Attributes=[IO.FileAttributes]::Normal} }
        [pscustomobject]@{FullName='F:\wootc\disks';PSIsContainer=$true;Attributes=[IO.FileAttributes]::Directory}
    } elseif ($LiteralPath -eq 'F:\wootc\disks') {
        [pscustomobject]@{FullName='F:\wootc\disks\root.disk';PSIsContainer=$false;Attributes=[IO.FileAttributes]::Normal}
    } else { throw 'Unexpected enumeration path' }
}
function Remove-Partition { param($InputObject,[switch]$Confirm,$ErrorAction)
    $script:removeCalls++
    if ($InputObject.Guid -ne $script:receipt.partitionGuid -or $InputObject.DriveLetter -ne 'F') { throw 'Removal did not bind actual target object' }
    if ($script:failRemove) { throw 'Mock removal failure' }
    if (-not $script:lieRemove) { $script:removed=$true }
    if ($script:swapSourceAfterRemove) { $script:source.Guid='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' }
}
function Get-PartitionSupportedSize { param($InputObject,$ErrorAction)
    if ($InputObject.Guid -ne $script:receipt.sourceCPartitionGuid) { throw 'Wrong resize source' }
    [pscustomobject]@{SizeMax=3000}
}
function Resize-Partition { param($InputObject,$Size,$ErrorAction)
    $script:resizeCalls++
    if ($script:failResize) { throw 'Mock resize failure' }
    if (-not $script:lieResize) { $script:source.Size=$Size }
}
function Assert-Refusal { param([scriptblock]$Setup,[string]$Name)
    Reset-Fixture; & $Setup
    $failed=$false
    try { Remove-WootcCreatedPartition -Drive F -Receipt $script:receipt -ExplicitRemoval | Out-Null } catch { $failed=$true }
    if (-not $failed -or $script:removeCalls -ne 0 -or $script:resizeCalls -ne 0) { throw "Unsafe policy passed or mutated storage: $Name" }
    Write-Output "PASS refusal: $Name"
}
Reset-Fixture
$result=Remove-WootcCreatedPartition -Drive F -Receipt $script:receipt -ExplicitRemoval
if ($result -ne 'partition-removal-and-extension-verified' -or $script:removeCalls -ne 1 -or $script:resizeCalls -ne 1) { throw 'Valid removal not positively observed' }
Write-Output 'PASS explicit bound removal and resize both observed'
Assert-Refusal { $script:enumerationError=$true } 'enumeration error'
Assert-Refusal { $script:diskEnumerationError=$true } 'disk enumeration error'
Assert-Refusal { $script:missingEnumeratedSource=$true } 'incomplete full disk enumeration'
Assert-Refusal { $script:foreignRoot=$true } 'foreign root file'
Assert-Refusal { $script:foreignNested=$true } 'foreign file inside installer namespace'
Assert-Refusal { $script:reparse=$true } 'junction before descent'
Assert-Refusal { $script:missingSource=$true } 'missing source C partition'
Assert-Refusal { $script:duplicateTarget=$true } 'ambiguous partition'
Assert-Refusal { $script:volume.FileSystemType='FAT32' } 'wrong filesystem'
Assert-Refusal { $script:volume.FileSystemLabel='personal' } 'wrong label'
Assert-Refusal { $script:target.GptType='{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } 'EFI type'
Assert-Refusal { $script:target.IsSystem=$true } 'system partition'
Assert-Refusal { $script:target.IsBoot=$true } 'boot partition'
Assert-Refusal { $script:target.Guid='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' } 'wrong partition GUID'
Assert-Refusal { $script:disk.Guid='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' } 'wrong disk GUID'
Assert-Refusal { $script:target.DiskNumber=1 } 'different Windows disk'
Assert-Refusal { $script:source.Guid='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' } 'wrong source C GUID'
Assert-Refusal { $script:receipt=$null } 'missing creation receipt'
Reset-Fixture
Get-WootcPartitionRemovalBinding -Drive F -Receipt $script:receipt | Out-Null
$script:swapAtQuery=2
$failed=$false
try { Remove-WootcCreatedPartition -Drive F -Receipt $script:receipt -ExplicitRemoval | Out-Null } catch { $failed=$true }
if (-not $failed -or $script:removeCalls -ne 0) { throw 'Earlier assessment authorized swapped partition' }
Write-Output 'PASS revalidation refuses identity swapped after assessment'
Reset-Fixture
$failed=$false
try { Remove-WootcCreatedPartition -Drive F -Receipt $script:receipt | Out-Null } catch { $failed=$true }
if (-not $failed -or $script:removeCalls -ne 0) { throw 'Missing explicit removal choice mutated storage' }
Write-Output 'PASS explicit removal choice required'
foreach ($failure in @('lieRemove','failRemove','lieResize','failResize','swapSourceAfterRemove')) {
    Reset-Fixture
    Set-Variable -Name $failure -Scope Script -Value $true
    $failed=$false
    try { Remove-WootcCreatedPartition -Drive F -Receipt $script:receipt -ExplicitRemoval | Out-Null } catch { $failed=$true }
    if (-not $failed) { throw "Unobserved destructive result passed: $failure" }
    if ($failure -in @('lieRemove','failRemove','swapSourceAfterRemove') -and $script:resizeCalls -ne 0) { throw 'Resize ran without verified deletion and source identity' }
    Write-Output "PASS refusal: $failure"
}

Reset-Fixture
$script:failResize=$true
try { Remove-WootcCreatedPartition -Drive F -Receipt $script:receipt -ExplicitRemoval | Out-Null } catch { }
if (-not $script:removed -or $script:removeCalls -ne 1) { throw 'Partial removal fixture did not reach extension failure' }
$script:failResize=$false
$result=Remove-WootcCreatedPartition -Drive F -Receipt $script:receipt -ExplicitRemoval -AllowExtensionRetry
if ($result -ne 'partition-removal-and-extension-verified' -or $script:removeCalls -ne 1 -or $script:resizeCalls -ne 2) { throw 'Retry deleted another partition or failed extension observation' }
Write-Output 'PASS retained receipt retries extension without another deletion'
Reset-Fixture
$newReceipt=New-WootcPartitionCreationReceipt -CreatedPartition $script:target -SourcePartition $script:source -SourceDiskGuid $script:disk.Guid
if ($newReceipt.partitionGuid -ne $script:receipt.partitionGuid -or $newReceipt.sourceCPartitionGuid -ne $script:receipt.sourceCPartitionGuid -or $newReceipt.sizeBytes -ne 1000) { throw 'Creation receipt did not record actual identities' }
Write-Output 'PASS creation receipt binds actual GPT objects'
Reset-Fixture
$failed=$false
try { New-WootcPartitionCreationReceipt -CreatedPartition $script:target -SourcePartition $script:source -SourceDiskGuid 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' | Out-Null } catch { $failed=$true }
if (-not $failed) { throw 'Creation receipt accepted changed original disk' }
Write-Output 'PASS creation receipt refuses changed original disk'

# Exercise the exact companion cleanup against disposable filesystem objects,
# independently of the storage command mocks. No C: installer tree is touched.
$temporary=Join-Path $env:TEMP "wootc-partition-policy-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory((Join-Path $temporary 'wootc/install')) | Out-Null
try {
    $owned=Join-Path $temporary 'wootc/state.json'
    $foreign=Join-Path $temporary 'wootc/photo.jpg'
    [IO.File]::WriteAllText($owned, 'owned-state')
    [IO.File]::WriteAllText($foreign, 'foreign-bytes')
    $failed=$false
    try { Remove-WootcInstallerFiles -Root $temporary | Out-Null } catch { $failed=$true }
    if (-not $failed -or [IO.File]::ReadAllText($foreign) -ne 'foreign-bytes' -or -not [IO.File]::Exists($owned)) { throw 'Companion preflight did not preserve foreign data and owned state' }
    Write-Output 'PASS actual temporary companion foreign sibling preserves all bytes'
    [IO.File]::Delete($foreign)
    $result=Remove-WootcInstallerFiles -Root $temporary
    if ($result -ne 'companion-cleanup-verified' -or [IO.Directory]::Exists((Join-Path $temporary 'wootc'))) { throw 'Exact companion cleanup did not remove only owned files and empty directories' }
    Write-Output 'PASS actual temporary companion exact files and empty directories removed'
} finally { if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true) } }

Reset-Fixture
$result=Remove-WootcCreatedPartition -Drive F -Receipt $script:receipt -ExplicitRemoval -DeferExtension
if ($result -ne 'partition-removal-observed' -or $script:removeCalls -ne 1 -or $script:resizeCalls -ne 0) { throw 'Deletion observation did not precede extension' }
$result=Remove-WootcCreatedPartition -Drive '' -Receipt $script:receipt -ExplicitRemoval -AllowExtensionRetry
if ($result -ne 'partition-removal-and-extension-verified' -or $script:removeCalls -ne 1 -or $script:resizeCalls -ne 1) { throw 'Observed deletion retry did not bind original Windows source' }
Write-Output 'PASS separate observed deletion precedes extension and permits safe retry'
