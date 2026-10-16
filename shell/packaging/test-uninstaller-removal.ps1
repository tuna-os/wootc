#Requires -Version 7.2
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'wait-uninstaller-removal.ps1')
$root=Join-Path $env:TEMP "wootc-uninstaller-observation-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    $path=Join-Path $root 'owned-public-test.exe'
    [IO.File]::WriteAllText($path,'public owned fixture')
    $hash=(Get-FileHash -LiteralPath $path).Hash
    $refused=$false
    try { $null=Wait-ObservedUninstallerRemoval -Path $path -Sha256 $hash -TimeoutSeconds 1 } catch { $refused=$true }
    if (-not $refused -or (Get-FileHash -LiteralPath $path).Hash -cne $hash) { throw 'Deadline accepted or changed a retained file' }
    $refused=$false
    try { $null=Wait-ObservedUninstallerRemoval -Path $path -Sha256 ('0' * 64) } catch { $refused=$true }
    if (-not $refused -or (Get-FileHash -LiteralPath $path).Hash -cne $hash) { throw 'Changed identity accepted or removed' }
    [IO.File]::Delete($path)
    $null=Wait-ObservedUninstallerRemoval -Path $path -Sha256 $hash
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $refused=$false
    try { $null=Wait-ObservedUninstallerRemoval -Path $path -Sha256 $hash } catch { $refused=$true }
    if (-not $refused -or -not [IO.Directory]::Exists($path)) { throw 'Directory accepted or removed' }
    [IO.Directory]::Delete($path,$false)
    # Actual later removal, not a mocked File.Exists response.
    [IO.File]::WriteAllText($path,'public owned fixture')
    $info=[Diagnostics.ProcessStartInfo]::new('pwsh')
    $info.UseShellExecute=$false
    $literalPath=$path.Replace("'","''")
    foreach ($argument in @('-NoProfile','-Command',"Start-Sleep -Milliseconds 250; [IO.File]::Delete('$literalPath')")) { $info.ArgumentList.Add($argument) }
    $child=[Diagnostics.Process]::Start($info)
    try {
        $elapsed=Wait-ObservedUninstallerRemoval -Path $path -Sha256 $hash -TimeoutSeconds 10
        if (-not $child.WaitForExit(10000) -or $child.ExitCode -ne 0 -or [IO.File]::Exists($path) -or $elapsed -le 0) { throw 'Actual later removal was not observed' }
    } finally { if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }; $child.Dispose() }
} finally { [IO.Directory]::Delete($root,$false) }
Write-Output 'PASS actual uninstaller observation: retained timeout, changed identity, directory, missing, later removal'
