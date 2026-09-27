# Native PowerShell 5.1 tests. Mock BitLocker cmdlets; only disposable files change.
param([string]$HelperPath = (Join-Path $PSScriptRoot 'fixture-bitlocker-key.ps1'))
$ErrorActionPreference = 'Stop'
. ([scriptblock]::Create([IO.File]::ReadAllText($HelperPath)))
$dir = Join-Path $env:TEMP ('wootc-fixture-key-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
& icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not protect disposable test directory' }
# Public synthetic recovery password; each block is a valid multiple of 11.
$script:password = ((@('111111') * 8) -join '-')
$script:protector = $null
$script:adds = 0
$script:failAdd = $false
$script:status = 'EncryptionInProgress'
function Get-BitLockerVolume { param($MountPoint, $ErrorAction)
    if ($MountPoint -ne 'C:') { throw 'Wrong fixture volume' }
    [pscustomobject]@{ VolumeStatus=$script:status; KeyProtector=$script:protector }
}
function Add-BitLockerKeyProtector { [CmdletBinding()] param($MountPoint, [switch]$RecoveryPasswordProtector)
    if ($MountPoint -ne 'C:' -or -not $RecoveryPasswordProtector) { throw 'Wrong protector request' }
    $script:adds++
    if ($script:failAdd) { throw 'Simulated creation failure' }
    $script:protector = [pscustomobject]@{KeyProtectorType='RecoveryPassword'; RecoveryPassword=$script:password}
    Write-Output $script:password
    Write-Warning $script:password
    Write-Information $script:password
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
    $transcriptPath = Join-Path $dir 'synthetic-transcript.txt'
    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    try {
        $exportOutput = @(Export-WootcFixtureBitLockerKey -Destination $path -EnsureProtector *>&1)
    } finally { Stop-Transcript | Out-Null }
    if ($exportOutput.Count -ne 0) { throw 'Recovery material escaped an output stream' }
    if ((Get-Content -LiteralPath $transcriptPath -Raw) -match [regex]::Escape($script:password)) {
        throw 'Recovery material escaped into the OEM transcript'
    }
    Write-Output 'PASS synthetic recovery material suppressed from success/warning/information streams and transcript'
    if ($script:adds -ne 1 -or -not (Test-Path $path)) { throw 'Missing protector was not created and saved' }
    Write-Output 'PASS missing protector created and private key verified'
    $keyBytes = [IO.File]::ReadAllBytes($path)
    if ($keyBytes.Length -ne 57 -or $keyBytes[55] -ne 13 -or $keyBytes[56] -ne 10) {
        throw 'Recovery export must be 55 ASCII characters followed by CRLF'
    }
    $keyText = [Text.Encoding]::ASCII.GetString($keyBytes, 0, 55)
    if ($keyText -cne $script:password -or $keyText -notmatch '^[0-9]{6}(-[0-9]{6}){7}$') {
        throw 'Recovery export altered the canonical grouped password'
    }
    foreach ($keyByte in $keyBytes) {
        if ($keyByte -gt 127) { throw 'Recovery export must not contain a BOM or non-ASCII bytes' }
    }
    Write-Output 'PASS exported key is 55 canonical ASCII characters with seven separators and CRLF, no BOM'
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
    # Execute the old output-only behavior under a native transcript using the
    # public synthetic warning. This must expose the regression, not just match
    # source text. Restore the exact helper afterward.
    $originalHelper = Get-Content -LiteralPath $HelperPath -Raw
    $mutantHelper = $originalHelper.Replace('-WarningAction SilentlyContinue -InformationAction SilentlyContinue *> $null', '| Out-Null')
    if ($mutantHelper -ceq $originalHelper) { throw 'Privacy counterexample was not applied' }
    . ([ScriptBlock]::Create($mutantHelper))
    $script:protector=$null; $script:failAdd=$false
    $mutantTranscript = Join-Path $dir 'synthetic-old-behavior.txt'
    Start-Transcript -LiteralPath $mutantTranscript -Force | Out-Null
    try { Export-WootcFixtureBitLockerKey -Destination $path -EnsureProtector 3>$null } finally { Stop-Transcript | Out-Null }
    if ((Get-Content -LiteralPath $mutantTranscript -Raw) -notmatch [regex]::Escape($script:password)) {
        throw 'Old output-only behavior did not expose the synthetic warning in the transcript'
    }
    . ([ScriptBlock]::Create($originalHelper))
    Write-Output 'PASS actual old-behavior mutant exposes synthetic warning through native transcript'

} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
