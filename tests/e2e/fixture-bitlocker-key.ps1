# Dedicated E2E Windows fixture only. Never decrypt C: or log protector objects.
function Export-WootcFixtureBitLockerKey {
    param([Parameter(Mandatory=$true)][string]$Destination, [switch]$EnsureProtector)
    try {
        $volume = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
        if (-not $volume -or $volume.VolumeStatus -eq 'FullyDecrypted') {
            throw 'The fixture C: volume is not encrypted'
        }
        $kp = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
        if (-not $kp -and $EnsureProtector) {
            Add-BitLockerKeyProtector -MountPoint 'C:' -RecoveryPasswordProtector -ErrorAction Stop | Out-Null
            $volume = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
            $kp = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
        }
        if (-not $kp -or $kp.RecoveryPassword -notmatch '^[0-9]{6}(-[0-9]{6}){7}$') {
            throw 'No valid fixture recovery protector'
        }
        Set-Content -LiteralPath $Destination -Value $kp.RecoveryPassword -Encoding ASCII -ErrorAction Stop
        & icacls.exe $Destination /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not protect fixture recovery key' }
        $acl = Get-Acl -LiteralPath $Destination -ErrorAction Stop
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
        $saved = (Get-Content -LiteralPath $Destination -Raw -ErrorAction Stop).Trim()
        if ($saved -cne $kp.RecoveryPassword) { throw 'Fixture key readback failed' }
    } catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        # Do not expose cmdlet output, exception details, or the recovery password.
        throw 'BitLocker fixture recovery key preparation failed; refusing to arm the boot'
    }
}
