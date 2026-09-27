param(
    [string]$KeyHelperPath = (Join-Path $PSScriptRoot 'fixture-bitlocker-key.ps1'),
    [string]$ProtectionHelperPath = (Join-Path $PSScriptRoot 'fixture-bitlocker-protection.ps1')
)
$ErrorActionPreference = 'Stop'
. ([scriptblock]::Create([IO.File]::ReadAllText($KeyHelperPath)))
. ([scriptblock]::Create([IO.File]::ReadAllText($ProtectionHelperPath)))
$script:realDiagnostic = (Get-Command Write-WootcFixtureFailureMetadata).ScriptBlock
$script:realExport = (Get-Command Export-WootcFixtureBitLockerKeyCore).ScriptBlock
$script:realFactory = (Get-Command New-WootcFixturePrivatePipeline).ScriptBlock
$script:realGetAcl = Get-Command Get-Acl -CommandType Cmdlet
$script:realSetContent = Get-Command Set-Content -CommandType Cmdlet
$script:realGetContent = Get-Command Get-Content -CommandType Cmdlet
$script:realRemove = Get-Command Remove-Item -CommandType Cmdlet
$script:realIcacls = (Get-Command icacls.exe -CommandType Application).Source
$script:publicKey = '111111-111111-111111-111111-111111-111111-111111-111111'
$script:sensitiveMarker = 'PublicSensitiveDiagnosticMarker'
Add-Type -TypeDefinition @'
using System;
public sealed class WootcBrokenDiagnosticException : Exception {
    public WootcBrokenDiagnosticException(string message) : base(message) { }
    public new int HResult { get { throw new Exception("PublicSensitiveDiagnosticMarker"); } }
}
'@
$testId = [guid]::NewGuid().ToString('N')
$dir = Join-Path $env:TEMP "wootc-fixture-diagnostics-$testId"
if (Test-Path -LiteralPath $dir) { throw 'Disposable directory already exists' }
New-Item -ItemType Directory -Path $dir | Out-Null
& $script:realIcacls $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Cannot protect disposable diagnostic directory' }
$script:path = Join-Path $dir 'public-key.txt'
$transcript = Join-Path $dir 'public-transcript.txt'
function Reset-DiagnosticMock {
    $script:addCalls=0; $script:resumeCalls=0; $script:exportCalls=0
    $script:volume = [pscustomobject]@{MountPoint='C:';VolumeType='OperatingSystem';LockStatus='Unlocked';VolumeStatus='FullyEncrypted';EncryptionPercentage=100;ProtectionStatus='Off';KeyProtector=@(
        [pscustomobject]@{KeyProtectorType='RecoveryPassword';KeyProtectorId='{11111111-1111-4111-8111-111111111111}';RecoveryPassword=$script:publicKey},
        [pscustomobject]@{KeyProtectorType='Tpm';KeyProtectorId='{22222222-2222-4222-8222-222222222222}'}
    )}
}
function Get-BitLockerVolume { param($MountPoint,$ErrorAction)
    if ($MountPoint -ne 'C:') { throw 'Wrong mocked volume' }
    if ($script:case -eq 'queryWin32') { throw [ComponentModel.Win32Exception]::new(5, $script:sensitiveMarker) }
    $script:volume
}
function Get-Tpm { param($ErrorAction) [pscustomobject]@{TpmPresent=$true;TpmReady=$true} }
function Export-WootcFixtureBitLockerKeyCore { param($Destination,[switch]$EnsureProtector)
    $script:exportCalls++; Update-DiagnosticSpies
    if ($script:case -eq 'exportWin32') { throw [ComponentModel.Win32Exception]::new(5, $script:sensitiveMarker) }
    if ($script:case -eq 'receiptOversized') {
        [IO.File]::WriteAllText($script:WootcFixtureBeforeReceipt.path,('X'*16385))
        throw [ComponentModel.Win32Exception]::new(5,$script:sensitiveMarker)
    }
    if ($script:case -eq 'receiptMalformed') {
        [IO.File]::WriteAllText($script:WootcFixtureBeforeReceipt.path,'{"PublicSensitiveDiagnosticMarker":')
        throw [ComponentModel.Win32Exception]::new(5,$script:sensitiveMarker)
    }
    if ($script:case -eq 'alreadyOn') { return }
    if ($script:case -like 'key*') { & $script:realExport -Destination $Destination -EnsureProtector:$EnsureProtector }
}
function Write-WootcFixtureFailureMetadata {
    param($Scope,$Stage,$FailureRecord,$NativeExitCode)
    if ($script:case -eq 'writerFailure') { throw $script:sensitiveMarker }
    if ($script:case -eq 'prefixSecret') { return "bitlocker-fixture-failure $script:publicKey" }
    if ($script:case -eq 'malformedRecord') { return 'bitlocker-fixture-failure {"PublicSensitiveDiagnosticMarker":' }
    if ($script:case -eq 'unknownRecord') { return 'bitlocker-fixture-failure {"schemaVersion":1,"scope":"activation","diagnosticUnavailable":true,"extra":"PublicSensitiveDiagnosticMarker"}' }
    if ($script:case -eq 'duplicateRecord') { return 'bitlocker-fixture-failure {"schemaVersion":1,"scope":"activation","scope":"recovery-export","diagnosticUnavailable":true}' }
    & $script:realDiagnostic -Scope $Scope -Stage $Stage -FailureRecord $FailureRecord -NativeExitCode $NativeExitCode
}
function Add-BitLockerKeyProtector { [CmdletBinding()] param($MountPoint,[switch]$TpmProtector)
    $script:addCalls++; Update-DiagnosticSpies
    if ($script:case -eq 'brokenDiagnostic') { throw [WootcBrokenDiagnosticException]::new($script:sensitiveMarker) }
    throw [ComponentModel.Win32Exception]::new(5, $script:sensitiveMarker)
}
function Resume-BitLocker { [CmdletBinding()] param($MountPoint)
    $script:resumeCalls++; Update-DiagnosticSpies
    $exception = [Runtime.InteropServices.COMException]::new($script:sensitiveMarker, -2147024891)
    Write-Error -Exception $exception
}
function Set-Content { [CmdletBinding()] param($LiteralPath,$Value,$Encoding)
    if ($script:case -eq 'keyWrite') { throw [ComponentModel.Win32Exception]::new(5, $script:sensitiveMarker) }
    & $script:realSetContent -LiteralPath $LiteralPath -Value $Value -Encoding $Encoding -ErrorAction Stop
}
function Get-Acl { [CmdletBinding()] param($LiteralPath)
    if ($script:case -eq 'keyAclRead') { throw [ComponentModel.Win32Exception]::new(5, $script:sensitiveMarker) }
    $acl = & $script:realGetAcl -LiteralPath $LiteralPath -ErrorAction Stop
    if ($script:case -eq 'keyAclPolicy') {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule) # In-memory counterexample; no weakened real file ACL.
    }
    $acl
}
function icacls.exe {
    if ($script:case -eq 'keyNativeExit') {
        $global:LASTEXITCODE=23
        Write-Output $script:publicKey
        Write-Error $script:sensitiveMarker -ErrorAction Continue
        return
    }
    & $script:realIcacls @args
    $global:LASTEXITCODE=$LASTEXITCODE
}
function Get-Content { [CmdletBinding()] param($LiteralPath,[switch]$Raw)
    if ($script:case -in @('keyRead','keyCleanup')) { throw [ComponentModel.Win32Exception]::new(5, $script:sensitiveMarker) }
    if ($script:case -eq 'keyMismatch') { return 'Public mismatch' }
    & $script:realGetContent -LiteralPath $LiteralPath -Raw:$Raw -ErrorAction Stop
}
function Remove-Item { [CmdletBinding()] param($LiteralPath,[switch]$Force)
    if ($script:case -eq 'keyCleanup') {
        Write-Warning $script:publicKey
        Write-Information $script:sensitiveMarker
        throw $script:sensitiveMarker
    }
    & $script:realRemove -LiteralPath $LiteralPath -Force:$Force -ErrorAction SilentlyContinue
}
$script:spyPath = Join-Path $dir 'public-call-spies.json'
$moduleProbe = & $script:realFactory
try {
    $null = $moduleProbe.AddScript("Get-Command Get-BitLockerVolume,Add-BitLockerKeyProtector,Resume-BitLocker,Get-Tpm | Select-Object Name,ModuleName")
    $commands = @($moduleProbe.Invoke())
    if ($commands.Count -ne 4 -or @($commands | Where-Object { $_.Name -ne 'Get-Tpm' -and $_.ModuleName -ne 'BitLocker' }).Count -ne 0 -or @($commands | Where-Object { $_.Name -eq 'Get-Tpm' -and $_.ModuleName -eq 'TrustedPlatformModule' }).Count -ne 1) { throw 'Actual private pipeline imports failed' }
    Write-Output 'PASS actual private pipeline resolves three BitLocker cmdlets and Get-Tpm from Windows system modules without invoking them'
} finally { $moduleProbe.Dispose() }
$weakDir = Join-Path $dir 'public-untrusted-directory'
[IO.Directory]::CreateDirectory($weakDir) | Out-Null
$weakAcl = [IO.DirectoryInfo]::new($weakDir).GetAccessControl()
$weakRule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles,[Security.AccessControl.AccessControlType]::Allow)
$weakAcl.AddAccessRule($weakRule)
[IO.DirectoryInfo]::new($weakDir).SetAccessControl($weakAcl)
$unsafeChild=Join-Path $weakDir 'private-child'
[IO.Directory]::CreateDirectory($unsafeChild) | Out-Null
$inheritedDir=Join-Path $dir 'private-inherited-child'
[IO.Directory]::CreateDirectory($inheritedDir) | Out-Null
if ([IO.DirectoryInfo]::new($inheritedDir).GetAccessControl().AreAccessRulesProtected) { throw 'Inherited private leaf control is not inherited' }
$originalPath=$script:path
function Update-DiagnosticSpies {
    if (($script:addCalls+$script:resumeCalls+$script:exportCalls) -gt 0) {
        if ($null -eq $script:WootcFixtureBeforeReceipt) { throw 'Mutation preceded a durable receipt' }
        $observed=[IO.File]::ReadAllText($script:WootcFixtureBeforeReceipt.path)|ConvertFrom-Json
        if ($observed.stage -cne 'before' -or $observed.runId -cne $script:WootcFixtureRunId) { throw 'Mutation used a stale receipt' }
    }
    $json = [pscustomobject]@{adds=$script:addCalls;resumes=$script:resumeCalls;exports=$script:exportCalls} | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($script:spyPath,$json)
}
function New-WootcFixturePrivatePipeline {
    $pipeline = & $script:realFactory
    $setup = @'
param($case,$path,$spyPath)
$script:case=$case
$script:path=$path
$script:spyPath=$spyPath
$script:publicKey='111111-111111-111111-111111-111111-111111-111111-111111'
$script:sensitiveMarker='PublicSensitiveDiagnosticMarker'
$script:realDiagnostic=(Get-Command Write-WootcFixtureFailureMetadata).ScriptBlock
$script:realExport=(Get-Command Export-WootcFixtureBitLockerKeyCore).ScriptBlock
$script:realGetAcl=Get-Command Get-Acl -CommandType Cmdlet
$script:realSetContent=Get-Command Set-Content -CommandType Cmdlet
$script:realGetContent=Get-Command Get-Content -CommandType Cmdlet
$script:realRemove=Get-Command Remove-Item -CommandType Cmdlet
$script:realIcacls=(Get-Command icacls.exe -CommandType Application).Source
'@
    foreach ($name in @('Reset-DiagnosticMock','Update-DiagnosticSpies','Get-BitLockerVolume','Get-Tpm','Export-WootcFixtureBitLockerKeyCore','Write-WootcFixtureFailureMetadata','Add-BitLockerKeyProtector','Resume-BitLocker','Set-Content','Get-Acl','icacls.exe','Get-Content','Remove-Item')) {
        $definition=(Get-Command $name).Definition
        $setup += "`nfunction $name { $definition }`n"
    }
    $setup += @'
Reset-DiagnosticMock
if ($script:case -in @('enrollWin32','brokenDiagnostic','writerFailure','prefixSecret','malformedRecord','unknownRecord','duplicateRecord')) { $script:volume.KeyProtector=@($script:volume.KeyProtector[0]) }
if ($script:case -eq 'paused') { $script:volume.VolumeStatus='EncryptionPaused' }
if ($script:case -eq 'alreadyOn') { $script:volume.ProtectionStatus='On' }
Update-DiagnosticSpies
'@
    $null=$pipeline.AddScript($setup).AddArgument($script:case).AddArgument($script:path).AddArgument($script:spyPath)
    return $pipeline
}
$checks = @(
    @{name='alreadyOn';positive=$true},
    @{name='queryWin32';scope='activation';stage='query-volume';kind='operation-error';native=5},
    @{name='paused';scope='activation';stage='validate-volume';kind='policy-refusal'},
    @{name='exportWin32';scope='activation';stage='export-recovery';kind='operation-error';native=5},
    @{name='enrollWin32';scope='activation';stage='enroll-tpm';kind='operation-error';native=5},
    @{name='resumeCom';scope='activation';stage='enable-protection';kind='operation-error';hresult=-2147024891},
    @{name='keyWrite';scope='recovery-export';stage='write-key';kind='operation-error';native=5},
    @{name='keyNativeExit';scope='recovery-export';stage='protect-key';kind='operation-error';exit=23},
    @{name='keyAclRead';scope='recovery-export';stage='read-key-acl';kind='operation-error';native=5},
    @{name='keyAclPolicy';scope='recovery-export';stage='validate-key-acl';kind='policy-refusal'},
    @{name='keyRead';scope='recovery-export';stage='read-key';kind='operation-error';native=5},
    @{name='keyMismatch';scope='recovery-export';stage='validate-key-readback';kind='policy-refusal'},
    @{name='keyCleanup';scope='recovery-export';stage='read-key';kind='operation-error';native=5},
    @{name='brokenDiagnostic';scope='activation';stage='enroll-tpm';kind='operation-error';unknownType=$true},
    @{name='writerFailure';fallback=$true},
    @{name='receiptOversized';boundaryRefusal=$true;exportSpy=$true},
    @{name='receiptMalformed';boundaryRefusal=$true;exportSpy=$true},
    @{name='prefixSecret';boundaryRefusal=$true},
    @{name='malformedRecord';boundaryRefusal=$true},
    @{name='unknownRecord';boundaryRefusal=$true},
    @{name='duplicateRecord';boundaryRefusal=$true},
    @{name='receiptRefusal';scope='activation';stage='write-before-receipt';kind='operation-error'}
)
try {
    Start-Transcript -LiteralPath $transcript -Force | Out-Null
    try {
        foreach ($check in $checks) {
            Write-Output "BEGIN diagnostic case $($check.name)"
            Reset-DiagnosticMock
            $script:case=$check.name
            $script:path=$originalPath
            if ($script:case -eq 'receiptRefusal') { $script:path=Join-Path $unsafeChild 'public-key.txt' }
            if ($script:case -eq 'alreadyOn') { $script:path=Join-Path $inheritedDir 'public-key.txt' }
            if ($script:case -in @('enrollWin32','brokenDiagnostic','writerFailure','prefixSecret','malformedRecord','unknownRecord','duplicateRecord')) { $script:volume.KeyProtector=@($script:volume.KeyProtector[0]) }
            if ($script:case -eq 'paused') { $script:volume.VolumeStatus='EncryptionPaused' }
if ($script:case -eq 'alreadyOn') { $script:volume.ProtectionStatus='On' }
            $lines = [Collections.Generic.List[string]]::new()
            $failed=$false
            try { Initialize-WootcFixtureBitLockerProtection -RecoveryKeyPath $script:path | ForEach-Object { $lines.Add([string]$_) } } catch {
                $failed=$true
                if ($_.Exception.Message -ne 'BitLocker fixture protection activation failed; refusing to schedule installed Linux') { throw 'Original exception escaped final boundary' }
            }
            if ($check.positive) {
                if ($failed -or $lines.Count -ne 2 -or @($lines | Where-Object { $_ -like '*"ready":true*' }).Count -ne 1) { throw 'Actual private boundary rejected ready observations' }
                $spies=[IO.File]::ReadAllText($script:spyPath)|ConvertFrom-Json
                if ($spies.exports -ne 1 -or $spies.adds -ne 0 -or $spies.resumes -ne 0) { throw 'Ready child mocks did not preserve positive policy' }
                Write-Output "PUBLIC_READY_BEFORE $($lines[0])"
                Write-Output "PUBLIC_READY_FINAL $($lines[1])"
                Write-Output 'PASS actual private boundary preserves observed ready JSON and zero unnecessary enrollment/activation'
                continue
            }
            if (-not $failed) { throw 'Unsafe mock activation passed' }
            if ($check.boundaryRefusal) {
                if ($lines.Count -ne 0) { throw 'Unsafe boundary record was emitted' }
                $spies=[IO.File]::ReadAllText($script:spyPath)|ConvertFrom-Json
                if ($check.exportSpy) { if ($spies.exports -ne 1) { throw 'Receipt injection did not execute child export' } }
                elseif ($spies.adds -ne 1) { throw 'Record injection did not execute child operation' }
                Write-Output "PASS hostless boundary rejects unsafe record $script:case"
                continue
            }
            $text=$lines -join "`n"
            if ($text.Contains($script:publicKey) -or $text.Contains($script:sensitiveMarker) -or $text.Contains('WootcBrokenDiagnosticException')) { throw 'Sensitive mock exception material escaped' }
            $records=@($lines | Where-Object { $_ -like 'bitlocker-fixture-failure *' } | ForEach-Object { $_.Substring('bitlocker-fixture-failure '.Length) | ConvertFrom-Json })
            if ($check.fallback) {
                if (@($records | Where-Object { $_.scope -eq 'activation' -and $_.diagnosticUnavailable -eq $true }).Count -ne 1) { throw 'Broken diagnostic writer did not safely fall back' }
            } else {
                $record=@($records | Where-Object { $_.scope -eq $check.scope -and $_.stage -eq $check.stage })
                if ($record.Count -ne 1 -or $record[0].failureKind -ne $check.kind) { throw "Missing observed failure stage: $script:case" }
                if ($check.unknownType -and @($record[0].errors | Where-Object { $_.exceptionType -eq 'Other' }).Count -lt 1) { throw 'Unlisted exception type was not sanitized' }
                if ($check.ContainsKey('native') -and @($record[0].errors | Where-Object { $_.nativeCode -eq $check.native }).Count -ne 1) { throw 'Numeric native error was lost' }
                if ($check.ContainsKey('hresult') -and @($record[0].errors | Where-Object { $_.hresult -eq $check.hresult }).Count -ne 1) { throw 'Numeric HRESULT was lost' }
                if ($check.ContainsKey('exit') -and $record[0].nativeExitCode -ne $check.exit) { throw 'Numeric icacls exit was lost' }
                if ($check.scope -eq 'recovery-export' -and @($records | Where-Object { $_.scope -eq 'activation' -and $_.stage -eq 'export-recovery' }).Count -ne 1) { throw 'Nested exporter failure lost outer activation stage' }
            }
            $spies = [IO.File]::ReadAllText($script:spyPath) | ConvertFrom-Json
            if ($script:case -eq 'receiptRefusal' -and ($spies.exports -ne 0 -or $spies.adds -ne 0 -or $spies.resumes -ne 0)) { throw 'Untrusted receipt directory reached a mutation' }
            if ($script:case -notin @('queryWin32','paused','receiptRefusal')) {
                $receipts=@($lines | Where-Object { $_ -like 'bitlocker-fixture-receipt *' })
                if ($receipts.Count -ne 1) { throw 'Missing parent-validated durable before receipt' }
            }
            if ($script:case -notin @('resumeCom') -and $spies.resumes -ne 0) { throw 'Failure incorrectly reached Resume' }
            if ($script:case -notin @('enrollWin32','brokenDiagnostic','writerFailure','prefixSecret','malformedRecord','unknownRecord','duplicateRecord') -and $spies.adds -ne 0) { throw 'Failure incorrectly reached TPM enrollment' }
            if ($script:case -eq 'resumeCom' -and $spies.resumes -ne 1) { throw 'Child Resume mock was not exercised' }
            if ($script:case -in @('enrollWin32','brokenDiagnostic','writerFailure','prefixSecret','malformedRecord','unknownRecord','duplicateRecord') -and $spies.adds -ne 1) { throw 'Child enrollment mock was not exercised' }
            & $script:realRemove -LiteralPath $script:path -Force -ErrorAction SilentlyContinue
            Write-Output "PASS diagnostic case $script:case"
        }
    } finally { Stop-Transcript | Out-Null }
    $captured = [IO.File]::ReadAllText($transcript)
    if ($captured.Contains($script:publicKey) -or $captured.Contains($script:sensitiveMarker)) {
        $publicTranscriptBytes = [Text.Encoding]::UTF8.GetBytes($captured)
        Write-Output "PUBLIC_SYNTHETIC_TRANSCRIPT_BASE64 $([Convert]::ToBase64String($publicTranscriptBytes))"
        throw 'Sensitive mock material escaped into transcript'
    }
    $script:WootcFixtureRunId=[guid]::NewGuid().ToString('N')
    $collisionPath=Join-Path $dir 'public-collision-key.txt'
    Write-WootcFixtureBeforeReceipt -KeyPath $collisionPath -Metadata ([pscustomobject]@{schemaVersion=1;stage='before'})
    $collisionReceipt=$script:WootcFixtureBeforeReceipt.path
    $collisionBytes=[IO.File]::ReadAllBytes($collisionReceipt)
    $collisionFailed=$false
    try { Write-WootcFixtureBeforeReceipt -KeyPath $collisionPath -Metadata ([pscustomobject]@{schemaVersion=1;stage='before'}) } catch { $collisionFailed=$true }
    if (-not $collisionFailed -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($collisionReceipt)) -cne [Convert]::ToBase64String($collisionBytes)) { throw 'Exclusive receipt creation overwrote prior evidence' }
    Write-Output 'PASS exclusive receipt creation refuses same-run collision and preserves original bytes'
    Write-Output 'PASS durable before receipts validated and untrusted receipt ACL refuses all mutations'
    Write-Output 'PASS actual transcript rejects public sensitive strings, key output, warnings, information, original errors and cleanup errors'
} finally {
    & $script:realRemove -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
