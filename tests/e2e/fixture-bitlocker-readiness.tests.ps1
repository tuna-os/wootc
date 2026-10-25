param([string]$HelperPath = (Join-Path $PSScriptRoot 'fixture-bitlocker-readiness.ps1'))
$ErrorActionPreference = 'Stop'
. $HelperPath
$script:volume = $null
$script:queryError = $false
function Get-BitLockerVolume { param($MountPoint, $ErrorAction)
    if ($MountPoint -ne 'C:' -or $script:queryError) { throw 'Mock query failure' }
    $script:volume
}
foreach ($status in @('FullyEncrypted', 'FullyDecrypted', 'EncryptionInProgress', 'DecryptionInProgress', 'EncryptionPaused', 'DecryptionPaused')) {
    foreach ($protection in @('On', 'Off', 'Unknown')) {
        foreach ($percentage in @(0, 99, 100)) {
            $script:volume = [pscustomobject]@{VolumeStatus=$status; ProtectionStatus=$protection; EncryptionPercentage=$percentage}
            $output = Get-WootcFixtureBitLockerReadiness
            $expected = $status -eq 'FullyEncrypted' -and $percentage -eq 100 -and $protection -eq 'On'
            if ($output -ne "bitlocker-fixture status=$status percentage=$percentage protection=$protection ready=$expected") { throw 'Readiness mismatch' }
        }
    }
}
Write-Output 'PASS all 54 conversion/protection/percentage combinations; only fully encrypted 100 protection on passes'
foreach ($invalid in @($null, @([pscustomobject]@{}, [pscustomobject]@{}), [pscustomobject]@{VolumeStatus='FullyEncrypted';ProtectionStatus='On';EncryptionPercentage=$null}, [pscustomobject]@{VolumeStatus='FullyEncrypted';ProtectionStatus='On';EncryptionPercentage=101})) {
    $script:volume = $invalid
    $failed = $false
    try { Get-WootcFixtureBitLockerReadiness | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Invalid observation passed' }
}
$script:queryError = $true
$failed = $false
try { Get-WootcFixtureBitLockerReadiness | Out-Null } catch { $failed = $true }
if (-not $failed) { throw 'Query failure passed' }
Write-Output 'PASS missing duplicate malformed and failed observations refuse readiness'
