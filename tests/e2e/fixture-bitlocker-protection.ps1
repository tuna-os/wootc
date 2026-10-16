# Dedicated disposable E2E fixture only. Readiness stays a separate observation.
function Get-WootcFixtureCompleteEncryptedVolume {
    param([ref]$FailureStage)
    $volumes = @(Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop)
    if ($null -ne $FailureStage) { $FailureStage.Value = 'validate-volume' }
    if ($volumes.Count -ne 1) { throw 'Ambiguous fixture volume' }
    $volume = $volumes[0]
    if ($volume.MountPoint -ne 'C:' -or $volume.VolumeType -ne 'OperatingSystem' -or
        $volume.LockStatus -ne 'Unlocked' -or $volume.VolumeStatus -ne 'FullyEncrypted' -or
        [string]$volume.EncryptionPercentage -ne '100' -or $volume.ProtectionStatus -notin @('On', 'Off')) {
        throw 'Fixture identity or encryption conversion is not ready'
    }
    return $volume
}

function Get-WootcFixtureProtectorMetadata {
    param([Parameter(Mandatory=$true)]$Volume)
    $ids = @()
    if ($null -eq $Volume.KeyProtector) { return }
    foreach ($protector in @($Volume.KeyProtector)) {
        $id = [Guid]::Empty
        if ($protector.KeyProtectorType -notin @('Tpm', 'RecoveryPassword') -or
            -not [Guid]::TryParse([string]$protector.KeyProtectorId, [ref]$id) -or $id -eq [Guid]::Empty -or
            $ids -contains $id.ToString('D')) { throw 'Unknown or ambiguous fixture protector' }
        if ($protector.KeyProtectorType -eq 'RecoveryPassword' -and
            $protector.RecoveryPassword -notmatch '^[0-9]{6}(-[0-9]{6}){7}$') { throw 'Invalid fixture recovery protector' }
        $ids += $id.ToString('D')
        [pscustomobject]@{id=$id.ToString('D');type=[string]$protector.KeyProtectorType}
    }
}

function Initialize-WootcFixtureBitLockerProtectionCore {
    param([Parameter(Mandatory=$true)][string]$RecoveryKeyPath)
    $ErrorActionPreference = 'Stop'
    $stage = 'validate-os'
    try {
        if ($env:OS -ne 'Windows_NT') { throw 'Wrong OS' }
        $stage = 'query-volume'
        $volume = Get-WootcFixtureCompleteEncryptedVolume -FailureStage ([ref]$stage)
        $stage = 'query-tpm'
        $tpmState = Get-Tpm -ErrorAction Stop
        # Emit only a whitelist before any enrollment/export/activation. Invalid
        # identities get a constant placeholder rather than arbitrary text.
        $auditProtectors = @()
        foreach ($protector in @($volume.KeyProtector)) {
            if ($null -eq $volume.KeyProtector) { continue }
            $auditId = [Guid]::Empty
            $safeId = 'Invalid'
            if ([Guid]::TryParse([string]$protector.KeyProtectorId, [ref]$auditId)) { $safeId = $auditId.ToString('D') }
            $safeType = 'Unknown'
            $type = [string]$protector.KeyProtectorType
            if ($type -in @('Tpm','RecoveryPassword')) { $safeType = $type }
            $auditProtectors += [pscustomobject]@{id=$safeId;type=$safeType}
        }
        $present = $null
        $ready = $null
        if ($null -ne $tpmState -and $tpmState.TpmPresent -is [bool]) { $present = $tpmState.TpmPresent }
        if ($null -ne $tpmState -and $tpmState.TpmReady -is [bool]) { $ready = $tpmState.TpmReady }
        $beforeAudit = [pscustomobject]@{schemaVersion=1;stage='before';mountPoint='C:';volumeStatus=[string]$volume.VolumeStatus;percentage=100;protection=[string]$volume.ProtectionStatus;tpmPresent=$present;tpmReady=$ready;protectors=$auditProtectors}
        $stage = 'write-before-receipt'
        Write-WootcFixtureBeforeReceipt -KeyPath $RecoveryKeyPath -Metadata $beforeAudit
        $beforeJson = $beforeAudit | ConvertTo-Json -Compress -Depth 4
        Write-Output "bitlocker-fixture-metadata $beforeJson"
        $stage = 'validate-tpm'
        if ($null -eq $tpmState -or $tpmState.TpmPresent -isnot [bool] -or
            $tpmState.TpmReady -isnot [bool] -or -not $tpmState.TpmPresent -or -not $tpmState.TpmReady) {
            throw 'The fixture TPM is not positively ready'
        }
        # Verify existing typed identities before changing a protector. This
        # fixture supports TPM without a PIN for the unattended Windows return.
        $stage = 'validate-protectors'
        $before = @(Get-WootcFixtureProtectorMetadata -Volume $volume)
        if (@($before | Where-Object { $_.type -eq 'Tpm' }).Count -gt 1 -or
            @($before | Where-Object { $_.type -eq 'RecoveryPassword' }).Count -gt 1) { throw 'Ambiguous fixture protectors' }
        # Export creates a recovery protector only when absent, and verifies its
        # canonical bytes and private ACL before TPM enrollment or activation.
        $stage = 'export-recovery'
        Export-WootcFixtureBitLockerKeyCore -Destination $RecoveryKeyPath -EnsureProtector
        $stage = 'read-export-volume'
        $volume = Get-WootcFixtureCompleteEncryptedVolume -FailureStage ([ref]$stage)
        $stage = 'validate-protectors'
        $metadata = @(Get-WootcFixtureProtectorMetadata -Volume $volume)
        $recovery = @($metadata | Where-Object { $_.type -eq 'RecoveryPassword' })
        $tpm = @($metadata | Where-Object { $_.type -eq 'Tpm' })
        $stage = 'validate-export-identities'
        if ($recovery.Count -ne 1 -or $tpm.Count -gt 1) { throw 'Missing or ambiguous fixture recovery protector' }
        if ($tpm.Count -eq 0) {
            $stage = 'enroll-tpm'
            Add-BitLockerKeyProtector -MountPoint 'C:' -TpmProtector -ErrorAction Stop -WarningAction SilentlyContinue -InformationAction SilentlyContinue *> $null
            $stage = 'read-enrolled-volume'
            $volume = Get-WootcFixtureCompleteEncryptedVolume -FailureStage ([ref]$stage)
            $stage = 'validate-protectors'
            $metadata = @(Get-WootcFixtureProtectorMetadata -Volume $volume)
            $tpm = @($metadata | Where-Object { $_.type -eq 'Tpm' })
            $currentRecovery = @($metadata | Where-Object { $_.type -eq 'RecoveryPassword' })
            $stage = 'validate-enrollment'
            if ($tpm.Count -ne 1 -or $currentRecovery.Count -ne 1 -or
                $currentRecovery[0].id -ne $recovery[0].id) { throw 'TPM enrollment or recovery identity changed unexpectedly' }
            $stage = 'export-enrolled-recovery'
            Export-WootcFixtureBitLockerKeyCore -Destination $RecoveryKeyPath
        }
        if ($volume.ProtectionStatus -eq 'Off') {
            # Installed Microsoft module calls EnableKeyProtectors and checks
            # its return value. This removes clear-key exposure after enrollment.
            $stage = 'enable-protection'
            Resume-BitLocker -MountPoint 'C:' -ErrorAction Stop -WarningAction SilentlyContinue -InformationAction SilentlyContinue *> $null
        }
        $stage = 'read-active-volume'
        $observed = Get-WootcFixtureCompleteEncryptedVolume -FailureStage ([ref]$stage)
        $stage = 'validate-protectors'
        $observedMetadata = @(Get-WootcFixtureProtectorMetadata -Volume $observed)
        $stage = 'read-active-tpm'
        $finalTpm = Get-Tpm -ErrorAction Stop
        $stage = 'validate-active-tpm'
        if ($null -eq $finalTpm -or $finalTpm.TpmPresent -isnot [bool] -or
            $finalTpm.TpmReady -isnot [bool] -or -not $finalTpm.TpmPresent -or -not $finalTpm.TpmReady) {
            throw 'Fixture TPM readiness changed during activation'
        }
        $stage = 'validate-active-identities'
        if ($observed.ProtectionStatus -ne 'On' -or
            @($observedMetadata | Where-Object { $_.type -eq 'RecoveryPassword' -and $_.id -eq $recovery[0].id }).Count -ne 1 -or
            @($observedMetadata | Where-Object { $_.type -eq 'Tpm' -and $_.id -eq $tpm[0].id }).Count -ne 1 -or
            $observedMetadata.Count -ne 2) { throw 'Active protection with the enrolled identities was not observed' }
        $result = [pscustomobject]@{schemaVersion=1;mountPoint='C:';volumeStatus='FullyEncrypted';percentage=100;protection='On';tpmPresent=$true;tpmReady=$true;protectors=$observedMetadata;ready=$true}
        $result | ConvertTo-Json -Compress -Depth 4
    } catch {
        try { Write-WootcFixtureFailureMetadata -Scope 'activation' -Stage $stage -FailureRecord $_ } catch {
            try { Microsoft.PowerShell.Utility\Write-Output 'bitlocker-fixture-failure {"schemaVersion":1,"scope":"activation","diagnosticUnavailable":true}' } catch { }
        }
        # Protector objects and cmdlet exceptions may contain recovery secrets.
        throw 'BitLocker fixture protection activation failed; refusing to schedule installed Linux'
    }
}

function Initialize-WootcFixtureBitLockerProtection {
    param([Parameter(Mandatory=$true)][string]$RecoveryKeyPath)
    Invoke-WootcFixturePrivateOperation -Operation activate -Path $RecoveryKeyPath -EnsureProtector $true
}
$script:WootcFixtureProtectionClosure = "function Get-WootcFixtureCompleteEncryptedVolume { $((Get-Command Get-WootcFixtureCompleteEncryptedVolume).Definition) }`nfunction Get-WootcFixtureProtectorMetadata { $((Get-Command Get-WootcFixtureProtectorMetadata).Definition) }`nfunction Initialize-WootcFixtureBitLockerProtectionCore { $((Get-Command Initialize-WootcFixtureBitLockerProtectionCore).Definition) }`n"
