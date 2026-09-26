# Native Windows contract test; run elevated. Touches only a fresh temporary
# tree. Linux PowerShell cannot implement Windows ACLs and is not a substitute.
param([string]$HelperPath = (Join-Path $PSScriptRoot 'state-trust.ps1'))
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Run this native ACL test on Windows'
}
. $HelperPath

function Assert-Refused([scriptblock]$Operation, [string]$Reason, [string]$Expected) {
    $refused = $false
    try { & $Operation } catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
        $refused = $true
        Write-Output "refused ${Reason}: $($_.Exception.Message)"
    }
    if (-not $refused) { throw "unsafe condition accepted: $Reason" }
}

# Prove owner, effective and future-child permissions, parent delete rights,
# absent DACL, and SID-based matching without localized group names.
foreach ($sddl in @(
    'O:BUD:P(A;;FA;;;BA)',
    'O:BAD:NO_ACCESS_CONTROL',
    'O:BAD:(A;;FW;;;BU)',
    'O:BAD:(A;OICIIO;FW;;;BU)',
    'O:BAD:(A;;WD;;;BU)',
    'O:BAD:(A;;WO;;;BU)')) {
    $sd = New-Object System.Security.AccessControl.RawSecurityDescriptor($sddl)
    $expected = 'DACL gives mutation rights'
    if ($sddl.StartsWith('O:BU')) { $expected = 'owner is not' }
    if ($sddl.Contains('NO_ACCESS_CONTROL')) { $expected = 'missing DACL' }
    Assert-Refused { Assert-WootcStateDescriptor -Descriptor $sd } $sddl $expected
}
$parentSD = New-Object System.Security.AccessControl.RawSecurityDescriptor('O:BAD:(A;;0x40;;;BU)')
Assert-Refused { Assert-WootcStateDescriptor -Descriptor $parentSD -VolumeRoot } 'parent DELETE_CHILD' 'DACL gives mutation rights'
$createSD = New-Object System.Security.AccessControl.RawSecurityDescriptor('O:BAD:(A;;0x6;;;BU)(A;;FA;;;BA)')
Assert-WootcStateDescriptor -Descriptor $createSD -VolumeRoot
Assert-Refused { Initialize-WootcStateDirectory -Path 'C:\wootc\..\other' } 'invalid root' 'invalid installer state location'

$base = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
[IO.Directory]::CreateDirectory($base) | Out-Null
try {
    $root = Join-Path $base 'wootc'
    Initialize-WootcStateTree -Path $root
    $install = Join-Path $root 'install'
    [IO.Directory]::CreateDirectory($install) | Out-Null
    $manifest = Join-Path $install 'SHA256SUMS'
    $source = Join-Path $base 'source-fixture'
    [IO.File]::WriteAllText($source, 'administrator-staged fixture')
    Copy-Item -LiteralPath $source -Destination $manifest
    Initialize-WootcStateTree -Path $root
    if ([IO.File]::ReadAllText($manifest) -ne 'administrator-staged fixture') { throw 'safe fixture changed' }
    Write-Output 'PASS protected creation and offline rerun'

    $saved = Get-Acl -LiteralPath $manifest
    $unsafe = Get-Acl -LiteralPath $manifest
    $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($users, 'Write', 'Allow')
    $unsafe.AddAccessRule($rule)
    Set-Acl -LiteralPath $manifest -AclObject $unsafe
    $before = (Get-Acl -LiteralPath $manifest).Sddl
    Assert-Refused { Initialize-WootcStateTree -Path $root } 'planted writable manifest' 'DACL gives mutation rights'
    if ((Get-Acl -LiteralPath $manifest).Sddl -ne $before) { throw 'unsafe manifest ACL was repaired' }
    if ([IO.File]::ReadAllText($manifest) -ne 'administrator-staged fixture') { throw 'unsafe manifest changed' }
    Set-Acl -LiteralPath $manifest -AclObject $saved

    $unsafeRoot = Join-Path $base 'untrusted'
    [IO.Directory]::CreateDirectory($unsafeRoot) | Out-Null
    $acl = Get-Acl -LiteralPath $unsafeRoot
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $unsafeRoot -AclObject $acl
    $before = (Get-Acl -LiteralPath $unsafeRoot).Sddl
    Assert-Refused { Initialize-WootcStateTree -Path $unsafeRoot } 'precreated writable root' 'DACL gives mutation rights'
    if ((Get-Acl -LiteralPath $unsafeRoot).Sddl -ne $before) { throw 'unsafe root ACL was repaired' }

    $target = Join-Path $base 'junction-target'
    [IO.Directory]::CreateDirectory($target) | Out-Null
    $junction = Join-Path $root 'junction'
    New-Item -ItemType Junction -Path $junction -Value $target | Out-Null
    Assert-Refused { Initialize-WootcStateTree -Path $root } 'junction' 'reparse points are not allowed'
    # Delete the junction itself rather than recursively following its target.
    [IO.Directory]::Delete($junction)
    Write-Output 'PASS unsafe ownership/ACLs/reparse points fail without repair'
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force
}
