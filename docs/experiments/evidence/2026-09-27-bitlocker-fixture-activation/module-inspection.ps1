$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Expected Windows' }
$command=Get-Command Add-BitLockerKeyProtector -ErrorAction Stop
$modulePath=$command.Module.Path
Write-Output "MODULE $modulePath"
Write-Output "SHA256 $((Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash)"
$lines=@(Get-Content -LiteralPath $modulePath)
for ($index=0; $index -lt $lines.Count; $index++) {
    if ($lines[$index] -match 'function Add-RecoveryPasswordProtectorInternal|function Resume-BitLocker|Write-Warning|Write-Host|Write-Information|EnableKeyProtectors|ProtectKeyWithTPM') {
        Write-Output "LINE $index $($lines[$index])"
    }
}
