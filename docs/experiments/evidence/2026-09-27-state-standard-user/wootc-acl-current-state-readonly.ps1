$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$p='C:\wootc\state.json'
$exists=Test-Path -LiteralPath $p
$row=[ordered]@{schemaVersion=1;readOnly=$true;path=$p;exists=$exists;rootExists=(Test-Path -LiteralPath 'C:\wootc');sha256=$null;size=$null}
if($exists){$item=Get-Item -LiteralPath $p; if($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Unexpected state object type'};$row.sha256=(Get-FileHash -LiteralPath $p).Hash.ToLowerInvariant();$row.size=$item.Length}
$row|ConvertTo-Json -Compress
