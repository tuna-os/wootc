# Shared OEM/GUI fixture boundary. Dot-source before touching installer state.
# Keep this policy aligned with app/state_trust_windows.go. Existing unsafe
# payloads must be refused, never made trustworthy by resetting their ACLs.

function Test-WootcPrivilegedSid([string]$Sid) {
    return $Sid -in @('S-1-5-18', 'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
}

function Assert-WootcStateDescriptor {
    param([System.Security.AccessControl.RawSecurityDescriptor]$Descriptor,
          [switch]$VolumeRoot)
    if (-not $Descriptor.Owner -or -not (Test-WootcPrivilegedSid $Descriptor.Owner.Value)) {
        throw 'owner is not SYSTEM, Administrators or TrustedInstaller'
    }
    if ($null -eq $Descriptor.DiscretionaryAcl) { throw 'missing DACL permits unrestricted access' }
    # Generic all/write, WRITE_OWNER, WRITE_DAC, DELETE and FILE_DELETE_CHILD.
    # Use the actual filesystem bit 0x40; SDDL DC is a different (directory
    # service) right and would not catch deletion via the parent filesystem.
    $mutation = [int64]0x500D0040
    if (-not $VolumeRoot) { $mutation = $mutation -bor 0x116 }
    foreach ($ace in $Descriptor.DiscretionaryAcl) {
        $inheritOnly = ([int]$ace.AceFlags -band 8) -ne 0
        if ($VolumeRoot -and $inheritOnly) { continue }
        switch ([int]$ace.AceType) {
            1 { continue } # AccessDenied cannot make an unsafe allow trusted.
            0 {
                $sid = $ace.SecurityIdentifier.Value
                if ($inheritOnly -and $sid -eq 'S-1-3-0') { continue } # CREATOR OWNER
                if (([int64]$ace.AccessMask -band $mutation) -ne 0 -and -not (Test-WootcPrivilegedSid $sid)) {
                    throw "DACL gives mutation rights to $sid"
                }
            }
            default { throw "unsupported DACL entry type $($ace.AceType)" }
        }
    }
}

function Assert-WootcStateObject {
    param([string]$Path, [switch]$VolumeRoot)
    # File.GetAttributes inspects the link itself. Only a positively checked
    # parent is traversed, so an ordinary user cannot replace a checked child.
    $attributes = [IO.File]::GetAttributes($Path)
    if (([int]$attributes -band 0x400) -ne 0) {
        throw "unsafe installer state ${Path}: reparse points are not allowed"
    }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $descriptor = New-Object System.Security.AccessControl.RawSecurityDescriptor($acl.Sddl)
    try { Assert-WootcStateDescriptor -Descriptor $descriptor -VolumeRoot:$VolumeRoot }
    catch { throw "unsafe installer state ${Path}: $($_.Exception.Message)" }
}

function Assert-WootcStateTree([string]$Path) {
    Assert-WootcStateObject -Path $Path
    if (([int][IO.File]::GetAttributes($Path) -band 0x10) -ne 0) {
        foreach ($child in [IO.Directory]::GetFileSystemEntries($Path)) {
            Assert-WootcStateTree -Path $child
        }
    }
}

function New-WootcStateSecurity {
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    return $security
}

function Initialize-WootcStateTree([string]$Path) {
    # This overload installs security at creation, without an inherited-ACL
    # window. For an existing path it returns the existing directory and does
    # not repair its permissions. Audit before any subsequent ACL change.
    $security = New-WootcStateSecurity
    [IO.Directory]::CreateDirectory($Path, $security) | Out-Null
    Assert-WootcStateTree -Path $Path
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.SetSecurityDescriptorSddlForm('D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)',
        [System.Security.AccessControl.AccessControlSections]::Access)
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Initialize-WootcStateDirectory([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:\\wootc$') { throw "invalid installer state location $Path" }
    Assert-WootcStateObject -Path ([IO.Path]::GetPathRoot($Path)) -VolumeRoot
    Initialize-WootcStateTree -Path $Path
}
