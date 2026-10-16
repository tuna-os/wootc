$ErrorActionPreference='Stop'
$d=Join-Path $env:TEMP ([guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($d)|Out-Null
& icacls.exe $d /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' *> $null
$p=Join-Path $d 'public.txt'
try {
 Start-Transcript -LiteralPath $p | Out-Null
 try {
  $ps=[powershell]::Create()
  try {
   $null=$ps.AddScript('try { throw "PublicSensitiveDiagnosticMarker" } catch { "SAFE" }; Write-Warning "PublicSensitiveDiagnosticMarker"; Write-Information "PublicSensitiveDiagnosticMarker"; Write-Host "PublicSensitiveDiagnosticMarker"')
   $result=$ps.Invoke()
   Write-Output "RESULT $($result.Count)"
  } finally {$ps.Dispose()}
 } finally {Stop-Transcript|Out-Null}
 $s=[IO.File]::ReadAllText($p)
 Write-Output "HOSTLESS_TRANSCRIPT_LEAK $($s.Contains('PublicSensitiveDiagnosticMarker'))"
} finally {Remove-Item -LiteralPath $d -Recurse -Force}
