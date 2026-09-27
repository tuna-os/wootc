# Native PowerShell 5.1 tests. Mock BitLocker cmdlets; only disposable files change.
param([string]$HelperPath = (Join-Path $PSScriptRoot 'fixture-bitlocker-key.ps1'))
$ErrorActionPreference = 'Stop'
. $HelperPath
$dir = Join-Path $env:TEMP ('wootc-fixture-key-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
& icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not protect disposable test directory' }
$script:password = ((@('123456') * 8) -join '-')
$script:protector = $null
$script:adds = 0
$script:failAdd = $false
$script:status = 'EncryptionInProgress'
function Get-BitLockerVolume { param($MountPoint, $ErrorAction)
    if ($MountPoint -ne 'C:') { throw 'Wrong fixture volume' }
    [pscustomobject]@{ VolumeStatus=$script:status; KeyProtector=$script:protector }
}
function Add-BitLockerKeyProtector { param($MountPoint, [switch]$RecoveryPasswordProtector, $ErrorAction)
    if ($MountPoint -ne 'C:' -or -not $RecoveryPasswordProtector) { throw 'Wrong protector request' }
    $script:adds++
    if ($script:failAdd) { throw 'Simulated creation failure' }
    $script:protector = [pscustomobject]@{KeyProtectorType='RecoveryPassword'; RecoveryPassword=$script:password}
}
function Assert-Failure { param([scriptblock]$Action, [string]$Path)
    $failed=$false
    try { & $Action } catch {
        $failed=$true
        if ($_.Exception.Message -ne 'BitLocker fixture recovery key preparation failed; refusing to arm the boot') {
            throw 'Failure exposed unexpected details'
        }
    }
    if (-not $failed -or (Test-Path -LiteralPath $Path)) { throw 'Failed fixture retained a key or passed' }
}
try {
    $path = Join-Path $dir 'key.txt'
    Export-WootcFixtureBitLockerKey -Destination $path -EnsureProtector
    if ($script:adds -ne 1 -or -not (Test-Path $path)) { throw 'Missing protector was not created and saved' }
    Write-Output 'PASS missing protector created and private key verified'
    Export-WootcFixtureBitLockerKey -Destination $path -EnsureProtector
    if ($script:adds -ne 1) { throw 'Existing protector was duplicated' }
    Write-Output 'PASS existing protector reused'
    $script:protector=$null; $script:failAdd=$true
    Assert-Failure { Export-WootcFixtureBitLockerKey -Destination $path -EnsureProtector } $path
    Write-Output 'PASS creation failure stops and removes stale key'
    $script:failAdd=$false
    Assert-Failure { Export-WootcFixtureBitLockerKey -Destination $path } $path
    if ($script:adds -ne 2) { throw 'Refresh created a protector' }
    Write-Output 'PASS refresh refuses missing protector'
    $script:protector=[pscustomobject]@{KeyProtectorType='RecoveryPassword'; RecoveryPassword='invalid'}
    Assert-Failure { Export-WootcFixtureBitLockerKey -Destination $path -EnsureProtector } $path
    Write-Output 'PASS malformed password refused'
    $script:status='FullyDecrypted'
    Assert-Failure { Export-WootcFixtureBitLockerKey -Destination $path -EnsureProtector } $path
    Write-Output 'PASS plaintext fixture refused'
    $script:status='EncryptionInProgress'
    $script:protector=[pscustomobject]@{KeyProtectorType='RecoveryPassword'; RecoveryPassword=$script:password}
    function icacls.exe { $global:LASTEXITCODE=5 }
    Assert-Failure { Export-WootcFixtureBitLockerKey -Destination $path } $path
    Remove-Item Function:\icacls.exe
    Write-Output 'PASS permission failure stops and removes key'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
