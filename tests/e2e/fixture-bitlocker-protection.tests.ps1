param([string]$HelperPath = (Join-Path $PSScriptRoot 'fixture-bitlocker-protection.ps1'))
$ErrorActionPreference = 'Stop'
. $HelperPath
$script:publicKey = '111111-111111-111111-111111-111111-111111-111111-111111'
function New-MockProtector { param($Type,$Id)
    [pscustomobject]@{KeyProtectorType=$Type;KeyProtectorId=$Id;RecoveryPassword=$script:publicKey}
}
function Reset-Mock {
    $script:volume = [pscustomobject]@{MountPoint='C:';VolumeType='OperatingSystem';LockStatus='Unlocked';VolumeStatus='FullyEncrypted';EncryptionPercentage=100;ProtectionStatus='Off';KeyProtector=@(
        (New-MockProtector 'RecoveryPassword' '{11111111-1111-4111-8111-111111111111}'),
        (New-MockProtector 'Tpm' '{22222222-2222-4222-8222-222222222222}')
    )}
    $script:tpmState = [pscustomobject]@{TpmPresent=$true;TpmReady=$true}
    $script:resumeCalls=0; $script:addCalls=0; $script:exportCalls=0
    $script:queryError=$false; $script:exportError=$false; $script:exportSwap=$false
    $script:addError=$false; $script:addNoEffect=$false; $script:addDuplicate=$false; $script:addRecoverySwap=$false
    $script:resumeError=$false; $script:resumeNoEffect=$false; $script:resumeIdentitySwap=$false; $script:finalTpmUnavailable=$false
}
function Get-BitLockerVolume { param($MountPoint,$ErrorAction)
    if ($MountPoint -ne 'C:' -or $script:queryError) { throw 'Mock secret-bearing query error' }
    $script:volume
}
function Get-Tpm { param($ErrorAction) $script:tpmState }
function Export-WootcFixtureBitLockerKey { param($Destination,[switch]$EnsureProtector)
    if ($Destination -ne 'synthetic-private-key.txt') { throw 'Wrong private export destination' }
    $script:exportCalls++
    if ($script:exportError) { throw 'Mock secret-bearing export error' }
    $recovery=@($script:volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
    if ($recovery.Count -eq 0 -and $EnsureProtector) {
        $existing = @($script:volume.KeyProtector | Where-Object { $null -ne $_ })
        $script:volume.KeyProtector = @($existing)
        $script:volume.KeyProtector += New-MockProtector 'RecoveryPassword' '{11111111-1111-4111-8111-111111111111}'
    }
    if ($script:exportSwap) { $script:volume.MountPoint='D:' }
}
function Add-BitLockerKeyProtector { [CmdletBinding()] param($MountPoint,[switch]$TpmProtector)
    if ($MountPoint -ne 'C:' -or -not $TpmProtector -or $PSBoundParameters.ErrorAction -ne 'Stop') { throw 'Unexpected enrollment scope' }
    $script:addCalls++
    if ($script:addError) { throw 'Mock secret-bearing enrollment error' }
    if (-not $script:addNoEffect) { $script:volume.KeyProtector += New-MockProtector 'Tpm' '{22222222-2222-4222-8222-222222222222}' }
    if ($script:addDuplicate) { $script:volume.KeyProtector += New-MockProtector 'Tpm' '{33333333-3333-4333-8333-333333333333}' }
    if ($script:addRecoverySwap) { $script:volume.KeyProtector[0].KeyProtectorId='{44444444-4444-4444-8444-444444444444}' }
    Write-Output $script:publicKey
    Write-Warning $script:publicKey
}
function Resume-BitLocker { [CmdletBinding()] param($MountPoint)
    if ($MountPoint -ne 'C:' -or $PSBoundParameters.ErrorAction -ne 'Stop') { throw 'Unexpected activation scope' }
    $script:resumeCalls++
    if ($script:resumeError) { throw 'Mock secret-bearing activation error' }
    if (-not $script:resumeNoEffect) { $script:volume.ProtectionStatus='On' }
    if ($script:finalTpmUnavailable) { $script:tpmState.TpmReady=$false }
    if ($script:resumeIdentitySwap) { $script:volume.KeyProtector[0].KeyProtectorId='{44444444-4444-4444-8444-444444444444}' }
    Write-Output $script:publicKey
}
foreach ($initial in @('both','recoveryOnly','tpmOnly','none','nullProtectors','alreadyOn')) {
    Reset-Mock
    switch ($initial) {
        'recoveryOnly' {$script:volume.KeyProtector=@($script:volume.KeyProtector[0])}
        'tpmOnly' {$script:volume.KeyProtector=@($script:volume.KeyProtector[1])}
        'none' {$script:volume.KeyProtector=@()}
        'nullProtectors' {$script:volume.KeyProtector=$null}
        'alreadyOn' {$script:volume.ProtectionStatus='On'}
    }
    $output = @(Initialize-WootcFixtureBitLockerProtection -RecoveryKeyPath 'synthetic-private-key.txt')
    if ($output -match [regex]::Escape($script:publicKey)) { throw 'Secret escaped activation output' }
    if ($output.Count -ne 2 -or $output[0] -notlike 'bitlocker-fixture-metadata *') { throw 'Missing before-mutation metadata' }
    $before = $output[0].Substring('bitlocker-fixture-metadata '.Length) | ConvertFrom-Json
    if ($before.stage -ne 'before' -or $before.mountPoint -ne 'C:' -or $before.tpmReady -ne $true) { throw 'Before metadata is not actual fixture state' }
    $result = $output[-1] | ConvertFrom-Json
    if (-not $result.ready -or $result.protection -ne 'On' -or $result.protectors.Count -ne 2) { throw 'Missing observed active protector metadata' }
    $expectedAdd = [int]($initial -in @('recoveryOnly','none','nullProtectors'))
    $expectedResume = [int]($initial -ne 'alreadyOn')
    if ($script:addCalls -ne $expectedAdd -or $script:resumeCalls -ne $expectedResume -or $script:exportCalls -ne (1+$expectedAdd)) { throw 'Unexpected protector mutation/retry' }
}
Write-Output 'PASS six enrollment/activation paths including no existing protectors and already-on no mutation'
foreach ($case in @('missing','duplicate','wrongMount','wrongType','locked','decrypting','paused','inProgress','percentage','unknownProtection','malformedRecovery','unknownProtector','duplicateId','badId','duplicateTpm','duplicateRecovery','missingTpm','unreadyTpm','ambiguousTpm','exportError','exportSwap','queryError','addError','addNoEffect','addDuplicate','addRecoverySwap','resumeError','resumeNoEffect','resumeIdentitySwap','finalTpmUnavailable')) {
    Reset-Mock
    switch ($case) {
        'missing' {$script:volume=$null}
        'duplicate' {$script:volume=@($script:volume,$script:volume)}
        'wrongMount' {$script:volume.MountPoint='D:'}
        'wrongType' {$script:volume.VolumeType='Data'}
        'locked' {$script:volume.LockStatus='Locked'}
        'decrypting' {$script:volume.VolumeStatus='DecryptionInProgress'}
        'paused' {$script:volume.VolumeStatus='EncryptionPaused'}
        'inProgress' {$script:volume.VolumeStatus='EncryptionInProgress'}
        'percentage' {$script:volume.EncryptionPercentage=99}
        'unknownProtection' {$script:volume.ProtectionStatus='Unknown'}
        'malformedRecovery' {$script:volume.KeyProtector[0].RecoveryPassword='bad'}
        'unknownProtector' {$script:volume.KeyProtector[1].KeyProtectorType='TpmPin'}
        'duplicateId' {$script:volume.KeyProtector[1].KeyProtectorId=$script:volume.KeyProtector[0].KeyProtectorId}
        'badId' {$script:volume.KeyProtector[0].KeyProtectorId='invalid'}
        'duplicateTpm' {$script:volume.KeyProtector += New-MockProtector 'Tpm' '{33333333-3333-4333-8333-333333333333}'}
        'duplicateRecovery' {$script:volume.KeyProtector += New-MockProtector 'RecoveryPassword' '{33333333-3333-4333-8333-333333333333}'}
        'missingTpm' {$script:tpmState.TpmPresent=$false}
        'unreadyTpm' {$script:tpmState.TpmReady=$false}
        'ambiguousTpm' {$script:tpmState.TpmReady='True'}
        'exportError' {$script:exportError=$true}
        'exportSwap' {$script:exportSwap=$true}
        'queryError' {$script:queryError=$true}
        'addError' {$script:volume.KeyProtector=@($script:volume.KeyProtector[0]);$script:addError=$true}
        'addNoEffect' {$script:volume.KeyProtector=@($script:volume.KeyProtector[0]);$script:addNoEffect=$true}
        'addDuplicate' {$script:volume.KeyProtector=@($script:volume.KeyProtector[0]);$script:addDuplicate=$true}
        'addRecoverySwap' {$script:volume.KeyProtector=@($script:volume.KeyProtector[0]);$script:addRecoverySwap=$true}
        'resumeError' {$script:resumeError=$true}
        'resumeNoEffect' {$script:resumeNoEffect=$true}
        'resumeIdentitySwap' {$script:resumeIdentitySwap=$true}
        'finalTpmUnavailable' {$script:finalTpmUnavailable=$true}
    }
    $failed=$false
    try { Initialize-WootcFixtureBitLockerProtection -RecoveryKeyPath 'synthetic-private-key.txt' | Out-Null } catch {
        $failed=$true
        if ($_.Exception.Message -ne 'BitLocker fixture protection activation failed; refusing to schedule installed Linux') { throw 'Secret-bearing exception escaped' }
    }
    if (-not $failed) { throw "Unsafe activation accepted: $case" }
    if ($case -notin @('resumeError','resumeNoEffect','resumeIdentitySwap','finalTpmUnavailable') -and $script:resumeCalls -ne 0) { throw "Unsafe state reached Resume: $case" }
    if ($case -notin @('addError','addNoEffect','addDuplicate','addRecoverySwap') -and $script:addCalls -ne 0) { throw "Unsafe state reached enrollment: $case" }
}
Write-Output 'PASS 30 state/identity/TPM/export/enrollment/activation refusal controls; no secrets emitted'
