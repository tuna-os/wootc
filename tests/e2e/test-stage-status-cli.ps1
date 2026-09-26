param([string]$HelperPath = (Join-Path $PSScriptRoot 'stage-status-cli.ps1'))
$ErrorActionPreference='Stop'
. $HelperPath
$root=Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$source=Join-Path $root 'wootc.exe'
$manifest=Join-Path $root 'wootc.exe.sha256'
$destination=Join-Path $root 'copied.exe'
function Expect-Rejection {
    $rejected=$false
    try { Copy-WootcStatusCLI -SourceDirectory $root -Destination $destination } catch { $rejected=$true }
    if (-not $rejected) { throw 'Expected CLI staging rejection' }
}
try {
    Expect-Rejection
    [IO.File]::WriteAllText($source,'fixture executable bytes')
    Expect-Rejection
    [IO.File]::WriteAllText($manifest,('0' * 64))
    Expect-Rejection
    if (Test-Path $destination) { throw 'Failed preflight published an executable' }
    $hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($manifest,$hash)
    Copy-WootcStatusCLI -SourceDirectory $root -Destination $destination
    if ((Get-FileHash $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { throw 'Copied checksum differs' }
    Remove-Item -LiteralPath $source
    Expect-Rejection
    Write-Output 'PASS missing executable, missing checksum, corrupted payload, valid copy, and deleted staged executable'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
