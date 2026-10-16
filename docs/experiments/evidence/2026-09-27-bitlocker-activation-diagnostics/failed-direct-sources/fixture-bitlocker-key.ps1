# Dedicated E2E Windows fixture only. Never decrypt C: or log protector objects.
# Only fixed operation labels and numeric operating-system error codes may
# cross the fixture log boundary. Never inspect Message, ErrorDetails, Data,
# TargetObject, protector objects, or arbitrary exception type names.
function Write-WootcFixtureFailureMetadata {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('activation','recovery-export')][string]$Scope,
        [Parameter(Mandatory=$true)][ValidateSet('validate-os','validate-volume','query-volume','query-tpm','validate-tpm','validate-protectors','export-recovery','read-export-volume','validate-export-identities','enroll-tpm','read-enrolled-volume','validate-enrollment','export-enrolled-recovery','enable-protection','read-active-volume','read-active-tpm','validate-active-tpm','validate-active-identities','select-recovery','create-recovery','read-created-recovery','validate-recovery','write-key','protect-key','read-key-acl','validate-key-acl','read-key','validate-key-readback')][string]$Stage,
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

function Export-WootcFixtureBitLockerKey {
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
