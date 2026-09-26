function Copy-WootcStatusCLI {
    param([Parameter(Mandatory=$true)][string]$SourceDirectory,
          [Parameter(Mandatory=$true)][string]$Destination)
    $source = Join-Path $SourceDirectory 'wootc.exe'
    $manifest = Join-Path $SourceDirectory 'wootc.exe.sha256'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Status CLI executable is missing' }
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw 'Status CLI checksum is missing' }
    $expected = (Get-Content -LiteralPath $manifest -Raw).Trim().ToLowerInvariant()
    if ($expected -notmatch '^[0-9a-f]{64}$') { throw 'Invalid status CLI checksum' }
    $actual = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw 'Status CLI source checksum mismatch' }
    Copy-Item -LiteralPath $source -Destination $Destination -Force
    $copied = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($copied -ne $expected) { throw 'Status CLI staged checksum mismatch' }
    Write-Host "[wootc] Status CLI staged and verified: $expected"
}
