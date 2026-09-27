# Dedicated E2E Windows fixture only. Never decrypt C: or log protector objects.
# Only fixed operation labels and numeric operating-system error codes may
# cross the fixture log boundary. Never inspect Message, ErrorDetails, Data,
# TargetObject, protector objects, or arbitrary exception type names.
function Write-WootcFixtureFailureMetadata {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('activation','recovery-export')][string]$Scope,
        [Parameter(Mandatory=$true)][ValidateSet('validate-os','validate-volume','query-volume','query-tpm','validate-tpm','validate-protectors','export-recovery','read-export-volume','validate-export-identities','enroll-tpm','read-enrolled-volume','validate-enrollment','export-enrolled-recovery','enable-protection','read-active-volume','read-active-tpm','validate-active-tpm','validate-active-identities','select-recovery','create-recovery','read-created-recovery','validate-recovery','write-key','protect-key','read-key-acl','validate-key-acl','read-key','validate-key-readback','write-before-receipt')][string]$Stage,
        [Parameter(Mandatory=$true)][System.Management.Automation.ErrorRecord]$FailureRecord,
        [Nullable[int]]$NativeExitCode = $null
    )
    $allowedTypes = @('System.Management.Automation.RuntimeException','System.Management.Automation.ActionPreferenceStopException','System.Management.Automation.CmdletInvocationException','System.Management.Automation.ParameterBindingException','System.Management.Automation.CommandNotFoundException','System.UnauthorizedAccessException','System.IO.IOException','System.IO.FileNotFoundException','System.Runtime.InteropServices.COMException','System.ComponentModel.Win32Exception','Microsoft.Management.Infrastructure.CimException')
    $errors = @()
    $exception = $FailureRecord.Exception
    for ($depth=0; $null -ne $exception -and $depth -lt 4; $depth++) {
        $safeType = 'Other'
        $actualType = $exception.GetType().FullName
        if ($actualType -in $allowedTypes) { $safeType = $actualType }
        $nativeCode = $null
        if ($exception -is [System.ComponentModel.Win32Exception]) { $nativeCode = [int]$exception.NativeErrorCode }
        if ($actualType -eq 'Microsoft.Management.Infrastructure.CimException') { $nativeCode = [int]$exception.NativeErrorCode }
        $errors += [pscustomobject]@{exceptionType=$safeType;hresult=[int]$exception.HResult;nativeCode=$nativeCode}
        $exception = $exception.InnerException
    }
    $kind = 'operation-error'
    if ($Stage.StartsWith('validate-')) { $kind = 'policy-refusal' }
    $metadata = [pscustomobject]@{schemaVersion=1;scope=$Scope;stage=$Stage;failureKind=$kind;nativeExitCode=$NativeExitCode;category=[int]$FailureRecord.CategoryInfo.Category;errors=$errors}
    $json = $metadata | ConvertTo-Json -Compress -Depth 4
    Write-Output "bitlocker-fixture-failure $json"
}

function Export-WootcFixtureBitLockerKeyCore {
    param([Parameter(Mandatory=$true)][string]$Destination, [switch]$EnsureProtector)
    $stage = 'query-volume'
    $nativeExitCode = $null
    try {
        $volume = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
        $stage = 'validate-volume'
        if (-not $volume -or $volume.VolumeStatus -eq 'FullyDecrypted') {
            throw 'The fixture C: volume is not encrypted'
        }
        $stage = 'select-recovery'
        $kp = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
        if (-not $kp -and $EnsureProtector) {
            # The Windows cmdlet can write recovery material to warning/host
            # streams as well as success output. Prevent warning/information creation before transcript capture;
            # redirects alone do not protect a PowerShell transcript. Suppress
            # any remaining output streams;
            # terminating errors still reach the generic catch below.
            $stage = 'create-recovery'
            Add-BitLockerKeyProtector -MountPoint 'C:' -RecoveryPasswordProtector -ErrorAction Stop -WarningAction SilentlyContinue -InformationAction SilentlyContinue *> $null
            $stage = 'read-created-recovery'
            $volume = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
            $stage = 'select-recovery'
            $kp = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
        }
        $stage = 'validate-recovery'
        if (-not $kp -or $kp.RecoveryPassword -notmatch '^[0-9]{6}(-[0-9]{6}){7}$') {
            throw 'No valid fixture recovery protector'
        }
        $stage = 'write-key'
        Set-Content -LiteralPath $Destination -Value $kp.RecoveryPassword -Encoding ASCII -ErrorAction Stop
        $stage = 'protect-key'
        & icacls.exe $Destination /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' *> $null
        $nativeExitCode = [int]$LASTEXITCODE
        if ($nativeExitCode -ne 0) { throw 'Could not protect fixture recovery key' }
        $stage = 'read-key-acl'
        $acl = Get-Acl -LiteralPath $Destination -ErrorAction Stop
        $stage = 'validate-key-acl'
        if (-not $acl.AreAccessRulesProtected) { throw 'Fixture key inherits permissions' }
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        $allowed = @('S-1-5-18', 'S-1-5-32-544')
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin $allowed) { throw 'Unexpected fixture key owner' }
        if ($rules.Count -ne 2) { throw 'Unexpected fixture key permissions' }
        foreach ($rule in $rules) {
            if ($rule.IdentityReference.Value -notin $allowed -or $rule.AccessControlType -ne 'Allow' -or
                $rule.FileSystemRights -ne [System.Security.AccessControl.FileSystemRights]::FullControl) {
                throw 'Unexpected fixture key permissions'
            }
        }
        $stage = 'read-key'
        $saved = (Get-Content -LiteralPath $Destination -Raw -ErrorAction Stop).Trim()
        $stage = 'validate-key-readback'
        if ($saved -cne $kp.RecoveryPassword) { throw 'Fixture key readback failed' }
    } catch {
        if ($stage -ne 'protect-key') { $nativeExitCode = $null }
        try { Write-WootcFixtureFailureMetadata -Scope 'recovery-export' -Stage $stage -FailureRecord $_ -NativeExitCode $nativeExitCode } catch {
            try { Microsoft.PowerShell.Utility\Write-Output 'bitlocker-fixture-failure {"schemaVersion":1,"scope":"recovery-export","diagnosticUnavailable":true}' } catch { }
        }
        try { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -InformationAction SilentlyContinue *> $null } catch { }
        # Do not expose cmdlet output, exception details, or the recovery password.
        throw 'BitLocker fixture recovery key preparation failed; refusing to arm the boot'
    }
}

function Assert-WootcFixtureReceiptDirectory {
    param([string]$Directory)
    $item = [IO.DirectoryInfo]::new($Directory)
    if (-not $item.Exists) { throw 'Missing private receipt directory' }
    $allowed = @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $ancestor = $item
    while ($null -ne $ancestor) {
        if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Unsafe receipt ancestry' }
        $acl = $ancestor.GetAccessControl()
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $allowed) { throw 'Unsafe receipt ancestor owner' }
        # Creating unrelated siblings is harmless; deleting/replacing this
        # directory or changing its ACL is not. The leaf also forbids writes.
        $mask = 0x500D0040L
        if ($ancestor.FullName -eq $item.FullName) { $mask = $mask -bor 0x40000116L }
        foreach ($rule in @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))) {
            if (($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
            if ($rule.AccessControlType -eq 'Deny') { continue }
            if ($rule.AccessControlType -ne 'Allow') { throw 'Unknown receipt access rule' }
            if (([long]$rule.FileSystemRights -band $mask) -ne 0 -and $rule.IdentityReference.Value -notin $allowed) { throw 'Unsafe receipt ancestor access' }
        }
        $ancestor = $ancestor.Parent
    }
}

function Test-WootcFixtureInt32 {
    param($Value)
    return (($Value -is [int] -or $Value -is [long]) -and $Value -ge -2147483648L -and $Value -le 2147483647L)
}

function ConvertTo-WootcFixtureSafeRecord {
    param([string]$Record)
    $prefix=''
    $json=$Record
    foreach ($candidate in @('bitlocker-fixture-failure ','bitlocker-fixture-metadata ')) {
        if ($Record.StartsWith($candidate)) { $prefix=$candidate; $json=$Record.Substring($candidate.Length); break }
    }
    $value=$json | ConvertFrom-Json -ErrorAction Stop
    # Exact canonical round-trip rejects duplicate/case-aliased/escaped keys,
    # extra whitespace and alternate representations before any projection.
    if (($value | ConvertTo-Json -Compress -Depth 4) -cne $json) { throw 'Ambiguous fixture JSON' }
    $fields=@($value.PSObject.Properties.Name)
    $expected=@()
    if ($prefix -eq 'bitlocker-fixture-failure ') {
        if ($value.diagnosticUnavailable -is [bool] -and $value.diagnosticUnavailable -eq $true) {
            $expected=@('schemaVersion','scope','diagnosticUnavailable')
        } else {
            $expected=@('schemaVersion','scope','stage','failureKind','nativeExitCode','category','errors')
            $allowedStage=@('validate-os','validate-volume','query-volume','query-tpm','validate-tpm','validate-protectors','export-recovery','read-export-volume','validate-export-identities','enroll-tpm','read-enrolled-volume','validate-enrollment','export-enrolled-recovery','enable-protection','read-active-volume','read-active-tpm','validate-active-tpm','validate-active-identities','select-recovery','create-recovery','read-created-recovery','validate-recovery','write-key','protect-key','read-key-acl','validate-key-acl','read-key','validate-key-readback','write-before-receipt')
            if ($value.stage -cnotin $allowedStage -or $value.failureKind -cnotin @('policy-refusal','operation-error') -or -not (Test-WootcFixtureInt32 -Value $value.category) -or ($null -ne $value.nativeExitCode -and -not (Test-WootcFixtureInt32 -Value $value.nativeExitCode)) -or $value.errors -isnot [Array] -or $value.errors.Count -gt 4) { throw 'Invalid failure shape' }
            $allowedTypes=@('Other','System.Management.Automation.RuntimeException','System.Management.Automation.ActionPreferenceStopException','System.Management.Automation.CmdletInvocationException','System.Management.Automation.ParameterBindingException','System.Management.Automation.CommandNotFoundException','System.UnauthorizedAccessException','System.IO.IOException','System.IO.FileNotFoundException','System.Runtime.InteropServices.COMException','System.ComponentModel.Win32Exception','Microsoft.Management.Infrastructure.CimException')
            foreach ($errorValue in $value.errors) {
                if (@($errorValue.PSObject.Properties).Count -ne 3 -or @($errorValue.PSObject.Properties.Name | Where-Object { $_ -cnotin @('exceptionType','hresult','nativeCode') }).Count -ne 0 -or $errorValue.exceptionType -cnotin $allowedTypes -or -not (Test-WootcFixtureInt32 -Value $errorValue.hresult) -or ($null -ne $errorValue.nativeCode -and -not (Test-WootcFixtureInt32 -Value $errorValue.nativeCode))) { throw 'Invalid numeric error projection' }
            }
        }
        if ($value.scope -cnotin @('activation','recovery-export')) { throw 'Invalid failure scope' }
    } else {
        $expected=@('schemaVersion','mountPoint','volumeStatus','percentage','protection','tpmPresent','tpmReady','protectors','ready')
        if ($prefix -eq 'bitlocker-fixture-metadata ' -or $value.stage -ceq 'before') {
            $expected=@('schemaVersion','stage','mountPoint','volumeStatus','percentage','protection','tpmPresent','tpmReady','protectors')
            if ($value.stage -cne 'before') { throw 'Invalid before stage' }
            if ($prefix -eq '') {
                $expected += 'runId'
                if ($value.runId -isnot [string] -or $value.runId -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid before identity' }
            }
        } elseif ($value.ready -isnot [bool] -or -not $value.ready -or $value.protection -cne 'On' -or $value.tpmPresent -isnot [bool] -or -not $value.tpmPresent -or $value.tpmReady -isnot [bool] -or -not $value.tpmReady) { throw 'Invalid ready observation' }
        if ($value.mountPoint -cne 'C:' -or $value.volumeStatus -cne 'FullyEncrypted' -or -not (Test-WootcFixtureInt32 -Value $value.percentage) -or $value.percentage -ne 100 -or $value.protection -cnotin @('On','Off') -or ($null -ne $value.tpmPresent -and $value.tpmPresent -isnot [bool]) -or ($null -ne $value.tpmReady -and $value.tpmReady -isnot [bool]) -or $value.protectors -isnot [Array] -or $value.protectors.Count -gt 16) { throw 'Invalid volume projection' }
        foreach ($protector in $value.protectors) {
            if (@($protector.PSObject.Properties).Count -ne 2 -or @($protector.PSObject.Properties.Name | Where-Object { $_ -cnotin @('id','type') }).Count -ne 0 -or $protector.type -cnotin @('Tpm','RecoveryPassword','Unknown') -or $protector.id -isnot [string] -or ($protector.id -cne 'Invalid' -and $protector.id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')) { throw 'Invalid protector projection' }
        }
    }
    if (-not (Test-WootcFixtureInt32 -Value $value.schemaVersion) -or $value.schemaVersion -ne 1 -or $fields.Count -ne $expected.Count -or @($fields | Where-Object { $_ -cnotin $expected }).Count -ne 0) { throw 'Unknown or missing fixture fields' }
    return "$prefix$json"
}

function Read-WootcFixtureBoundedReceiptBytes {
    param([string]$Path)
    $item=[IO.FileInfo]::new($Path)
    if (-not $item.Exists -or ($item.Attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) -ne 0) { throw 'Unsafe receipt object' }
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $length=$stream.Length
        if ($length -lt 1 -or $length -gt 16384) { throw 'Invalid receipt size' }
        $bytes=[byte[]]::new([int]$length)
        $offset=0
        while ($offset -lt $bytes.Length) {
            $read=$stream.Read($bytes,$offset,$bytes.Length-$offset)
            if ($read -eq 0) { throw 'Incomplete receipt read' }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1 -or $stream.Length -ne $length) { throw 'Receipt size changed' }
        if (([IO.File]::GetAttributes($Path) -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) -ne 0) { throw 'Receipt object changed' }
        return ,$bytes
    } finally { $stream.Dispose() }
}

function Write-WootcFixtureBeforeReceipt {
    param([string]$KeyPath,$Metadata)
    if ($script:WootcFixtureRunId -notmatch '^[0-9a-f]{32}$') { throw 'Missing private run identity' }
    $fullKeyPath = [IO.Path]::GetFullPath($KeyPath)
    $directory = [IO.Path]::GetDirectoryName($fullKeyPath)
    Assert-WootcFixtureReceiptDirectory -Directory $directory
    $receiptPath = "$fullKeyPath.activation-$script:WootcFixtureRunId.json"
    $receiptMetadata = $Metadata | Select-Object schemaVersion,stage,mountPoint,volumeStatus,percentage,protection,tpmPresent,tpmReady,protectors
    $receiptMetadata | Add-Member -NotePropertyName runId -NotePropertyValue $script:WootcFixtureRunId
    $json = $receiptMetadata | ConvertTo-Json -Compress -Depth 4
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [IO.FileStream]::new($receiptPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $actual = Read-WootcFixtureBoundedReceiptBytes -Path $receiptPath
    if ([Convert]::ToBase64String($actual) -cne [Convert]::ToBase64String($bytes)) { throw 'Receipt readback changed' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($actual)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    $script:WootcFixtureBeforeReceipt = [pscustomobject]@{path=$receiptPath;sha256=$hash}
}

# The parent host may transcribe caught error messages before redirection or
# sanitization. Run secret-bearing cmdlets without a host and return only the
# helper's fixed records. Never stop or alter the caller's transcription.
function New-WootcFixturePrivatePipeline {
    $pipeline = [PowerShell]::Create()
    $closure = $script:WootcFixtureKeyClosure
    if ($null -ne $script:WootcFixtureProtectionClosure) { $closure += $script:WootcFixtureProtectionClosure }
    $imports = @'
$systemDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
$bitlockerModule = Join-Path $systemDirectory 'WindowsPowerShell\v1.0\Modules\BitLocker\BitLocker.psd1'
$tpmModule = Join-Path $systemDirectory 'WindowsPowerShell\v1.0\Modules\TrustedPlatformModule\TrustedPlatformModule.psd1'
Import-Module -Name $bitlockerModule -ErrorAction Stop *> $null
Import-Module -Name $tpmModule -ErrorAction Stop *> $null
'@
    $null = $pipeline.AddScript($imports)
    $null = $pipeline.AddScript($closure)
    return $pipeline
}

function Invoke-WootcFixturePrivateOperation {
    param([ValidateSet('export','activate')][string]$Operation,[string]$Path,[bool]$EnsureProtector,[ValidatePattern('^[0-9a-f]{32}$')][string]$RunId)
    $pipeline = $null
    $failed = $true
    if ([string]::IsNullOrEmpty($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $runId = $RunId
    try {
        $pipeline = New-WootcFixturePrivatePipeline
        $worker = @'
param($operation,$path,$ensureProtector,$runId)
$ErrorActionPreference='Stop'
$script:WootcFixtureRunId=$runId
$script:WootcFixtureBeforeReceipt=$null
$records = [Collections.Generic.List[string]]::new()
$failed=$false
try {
    if ($operation -eq 'export') {
        Export-WootcFixtureBitLockerKeyCore -Destination $path -EnsureProtector:$ensureProtector | ForEach-Object { $records.Add([string]$_) }
    } else {
        Initialize-WootcFixtureBitLockerProtectionCore -RecoveryKeyPath $path | ForEach-Object { $records.Add([string]$_) }
    }
} catch { $failed=$true }
try {
    $safeRecords = @($records | ForEach-Object { ConvertTo-WootcFixtureSafeRecord -Record $_ })
    if ($null -ne $script:WootcFixtureBeforeReceipt) {
        $receiptBytes=Read-WootcFixtureBoundedReceiptBytes -Path $script:WootcFixtureBeforeReceipt.path
        $receiptJson=[Text.Encoding]::UTF8.GetString($receiptBytes)
        $null=ConvertTo-WootcFixtureSafeRecord -Record $receiptJson
        $receiptValue=$receiptJson | ConvertFrom-Json
        if ($receiptValue.runId -cne $runId) { throw 'Changed receipt identity' }
    }
} catch { $failed=$true; $safeRecords=@(); $script:WootcFixtureBeforeReceipt=$null }
[pscustomobject]@{failed=$failed;records=$safeRecords;receipt=$script:WootcFixtureBeforeReceipt}
'@
        $null = $pipeline.AddScript($worker).AddArgument($Operation).AddArgument($Path).AddArgument($EnsureProtector).AddArgument($runId)
        $results = @($pipeline.Invoke())
        if ($results.Count -ne 1 -or $results[0].failed -isnot [bool]) { throw 'Invalid private result' }
        $receipt = $results[0].receipt
        if ($null -ne $receipt) {
            $fullKeyPath = [IO.Path]::GetFullPath($Path)
            $expected = "$fullKeyPath.activation-$runId.json"
            if ($receipt.path -cne $expected -or $receipt.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Invalid receipt scope' }
            Assert-WootcFixtureReceiptDirectory -Directory ([IO.Path]::GetDirectoryName($expected))
            if (([IO.File]::GetAttributes($expected) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Unsafe receipt file' }
            $bytes = Read-WootcFixtureBoundedReceiptBytes -Path $expected
            if ($bytes.Length -gt 16384) { throw 'Oversized receipt' }
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
            if ($hash -cne $receipt.sha256) { throw 'Receipt identity or bytes changed' }
            if ($results[0].failed) { Write-Output "bitlocker-fixture-receipt $expected SHA256 $hash" }
        }
        $records = @($results[0].records)
        if ($records.Count -gt 8) { throw 'Invalid private record count' }
        foreach ($record in $records) {
            if ($record -isnot [string] -or $record.Length -gt 16384) { throw 'Invalid private record' }
            # The child validated canonical JSON and every field/value before
            # returning this fixed record; no parent-host parser sees its input.
            Write-Output $record
        }
        $failed = $results[0].failed
    } catch { $failed=$true } finally { if ($null -ne $pipeline) { $pipeline.Dispose() } }
    if ($failed) {
        if ($Operation -eq 'export') { throw 'BitLocker fixture recovery key preparation failed; refusing to arm the boot' }
        throw 'BitLocker fixture protection activation failed; refusing to schedule installed Linux'
    }
}

function Get-WootcFixtureBeforeReceipt {
    param([Parameter(Mandatory=$true)][string]$RecoveryKeyPath,[Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId)
    $pipeline = $null
    try {
        $pipeline = New-WootcFixturePrivatePipeline
        $worker = @'
param($keyPath,$runId)
try {
    $path = "$keyPath.activation-$runId.json"
    Assert-WootcFixtureReceiptDirectory -Directory ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)))
    $acl = [IO.FileInfo]::new($path).GetAccessControl()
    $allowed = @('S-1-5-18','S-1-5-32-544')
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $allowed) { throw 'Unsafe receipt owner' }
    foreach ($rule in @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed) { throw 'Unsafe receipt access' }
    }
    $bytes = Read-WootcFixtureBoundedReceiptBytes -Path $path
    $json = [Text.Encoding]::UTF8.GetString($bytes)
    $safe = ConvertTo-WootcFixtureSafeRecord -Record $json
    $value = $safe | ConvertFrom-Json
    if ($value.stage -cne 'before' -or $value.runId -cne $runId) { throw 'Wrong receipt identity' }
    [pscustomobject]@{valid=$true;record=$safe}
} catch { [pscustomobject]@{valid=$false;record=$null} }
'@
        $null = $pipeline.AddScript($worker).AddArgument($RecoveryKeyPath).AddArgument($RunId)
        $result = @($pipeline.Invoke())
        if ($result.Count -ne 1 -or $result[0].valid -isnot [bool] -or -not $result[0].valid -or $result[0].record -isnot [string] -or $result[0].record.Length -gt 16384) { throw 'Unavailable fixture receipt' }
        Write-Output $result[0].record
    } catch { throw 'BitLocker fixture before receipt unavailable' } finally { if ($null -ne $pipeline) { $pipeline.Dispose() } }
}

function Export-WootcFixtureBitLockerKey {
    param([Parameter(Mandatory=$true)][string]$Destination,[switch]$EnsureProtector)
    Invoke-WootcFixturePrivateOperation -Operation export -Path $Destination -EnsureProtector $EnsureProtector.IsPresent
}

# Capture the loaded product implementations once. Command lookup later cannot
# substitute a helper with a same-name function in the caller's runspace.
$script:WootcFixtureKeyClosure = ''
foreach ($wootcHelperName in @('Write-WootcFixtureFailureMetadata','Export-WootcFixtureBitLockerKeyCore','Assert-WootcFixtureReceiptDirectory','Write-WootcFixtureBeforeReceipt','ConvertTo-WootcFixtureSafeRecord','Test-WootcFixtureInt32','Read-WootcFixtureBoundedReceiptBytes')) {
    $wootcHelperDefinition = (Get-Command $wootcHelperName).Definition
    $script:WootcFixtureKeyClosure += "`nfunction $wootcHelperName { $wootcHelperDefinition }`n"
}
