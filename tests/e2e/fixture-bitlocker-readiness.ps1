# Read-only fixture observation. Key export and encryption readiness are separate.
function Get-WootcFixtureBitLockerReadiness {
    $ErrorActionPreference = 'Stop'
    try {
        if ($env:OS -ne 'Windows_NT') { throw 'Wrong OS' }
        $volumes = @(Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop)
        if ($volumes.Count -ne 1) { throw 'Expected exactly one volume' }
        $volume = $volumes[0]
        $status = [string]$volume.VolumeStatus
        $protection = [string]$volume.ProtectionStatus
        if ($status -notin @('FullyDecrypted', 'FullyEncrypted', 'EncryptionInProgress', 'DecryptionInProgress', 'EncryptionPaused', 'DecryptionPaused')) { throw 'Invalid status' }
        if ($protection -notin @('On', 'Off', 'Unknown')) { throw 'Invalid protection' }
        $percentage = $volume.EncryptionPercentage
        if ($null -eq $percentage -or [string]$percentage -notmatch '^(100|[0-9]{1,2})$') { throw 'Invalid percentage' }
        $ready = $status -eq 'FullyEncrypted' -and [int]$percentage -eq 100 -and $protection -eq 'On'
        Write-Output "bitlocker-fixture status=$status percentage=$percentage protection=$protection ready=$ready"
    } catch {
        throw 'BitLocker fixture readiness observation failed'
    }
}
