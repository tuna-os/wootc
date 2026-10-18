param([Parameter(Mandatory=$true)][string]$VmUuid,
      [Parameter(Mandatory=$true)][string]$EspPartitionGuid,
      [Parameter(Mandatory=$true)][string]$LoaderPath,
      [Parameter(Mandatory=$true)][string]$TransportNonce)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Current guest is not Windows' }
$ActualUuid = (Get-CimInstance Win32_ComputerSystemProduct).UUID.ToLowerInvariant()
if ($ActualUuid -ne $VmUuid.ToLowerInvariant()) { throw 'Wrong actual scratch VM' }
if ($LoaderPath -notmatch '^\\EFI\\wootc-classic\\shimx64\.efi$') { throw 'Unsupported QA loader path' }
$Esp = @(Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' })
if ($Esp.Count -ne 1 -or $Esp[0].Guid.Trim('{}').ToLowerInvariant() -ne $EspPartitionGuid.ToLowerInvariant()) { throw 'Actual ESP identity differs' }
if (Test-Path 'Z:\') { throw 'Reserved QA ESP drive is in use' }
& mountvol.exe Z: /S | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot expose actual boot ESP' }
try {
    if (-not (Test-Path -LiteralPath 'Z:\EFI\wootc-classic\shimx64.efi' -PathType Leaf)) { throw 'QA signed loader absent' }
    $Copied = & bcdedit.exe /copy '{bootmgr}' /d 'wootc classic QA scratch'
    if ($LASTEXITCODE -ne 0) { throw 'Actual BCD copy failed' }
    $Ids = [regex]::Matches(($Copied -join "`n"), '\{[0-9a-fA-F-]{36}\}')
    if ($Ids.Count -ne 1) { throw 'Cannot identify copied BCD entry' }
    $Id = $Ids[0].Value
    & bcdedit.exe /set $Id device 'partition=Z:' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'BCD device write failed' }
    & bcdedit.exe /set $Id path $LoaderPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'BCD loader write failed' }
    $Readback = & bcdedit.exe /enum $Id /v
    if ($LASTEXITCODE -ne 0 -or -not (($Readback -join "`n").Contains($LoaderPath))) { throw 'Actual BCD loader readback differs' }
    & bcdedit.exe /bootsequence $Id | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Actual one-shot BCD arm failed' }
    [ordered]@{ os = $env:OS; vmUuid = $ActualUuid; bcdId = $Id;
      loaderPath = $LoaderPath; espPartitionGuid = $EspPartitionGuid;
      transportNonce = $TransportNonce } | ConvertTo-Json -Compress
} finally { & mountvol.exe Z: /D | Out-Null }
