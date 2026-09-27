$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if ($env:OS -ne 'Windows_NT') { throw 'Expected Windows fixture' }
Write-Output "NATIVE_POWERSHELL $($PSVersionTable.PSVersion)"
$dir=Join-Path $env:TEMP "wootc-optical-boot-mocks-$([guid]::NewGuid().ToString('N'))"
if (Test-Path -LiteralPath $dir) { throw 'Existing private directory' }
[IO.Directory]::CreateDirectory($dir) | Out-Null
& icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Private ACL failed' }
$originalOS=$env:OS
try {
$file0=Join-Path $dir 'source-0.ps1'
[IO.File]::WriteAllBytes($file0,[Convert]::FromBase64String('77u/DQokRXJyb3JBY3Rpb25QcmVmZXJlbmNlID0gIlN0b3AiDQppZiAoJGVudjpPUyAtbmUgIldpbmRvd3NfTlQiKSB7IHRocm93ICJFeHBlY3RlZCBXaW5kb3dzIGlkZW50aXR5IiB9DQokc3lzdGVtID0gR2V0LUNpbUluc3RhbmNlIC1DbGFzc05hbWUgV2luMzJfT3BlcmF0aW5nU3lzdGVtIC1FcnJvckFjdGlvbiBTdG9wDQppZiAoJG51bGwgLWVxICRzeXN0ZW0uTGFzdEJvb3RVcFRpbWUpIHsgdGhyb3cgIk1pc3NpbmcgV2luZG93cyBib290IG9ic2VydmF0aW9uIiB9DQokYm9vdFRpbWUgPSAkc3lzdGVtLkxhc3RCb290VXBUaW1lLlRvRmlsZVRpbWVVdGMoKQ0KJHJlY29yZCA9IEB7IHNjaGVtYVZlcnNpb24gPSAxOyBvcyA9ICRlbnY6T1M7IGJvb3RJZCA9ICIkYm9vdFRpbWUiIH0NCiRyZWNvcmQgfCBDb252ZXJ0VG8tSnNvbiAtQ29tcHJlc3MgLURlcHRoIDMNCg=='))
if ((Get-FileHash -LiteralPath $file0).Hash.ToLowerInvariant() -cne 'a09d9cfd082041c2230051b0dd0a2fb11f4e88f66b034a97fea7c37eed2528dc') { throw 'Staged hash mismatch' }
$tokens=$null; $parseErrors=$null; $null=[Management.Automation.Language.Parser]::ParseFile($file0,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'PS5.1 parse error' }
Write-Output 'SOURCE /tmp/wootc-bitlocker-media-acceptance/tests/e2e/windows-boot-observation.ps1 RAW b74a43410e579d013752acf77e181cc14542230904cfd4cfd83eacd74eb31324 STAGED a09d9cfd082041c2230051b0dd0a2fb11f4e88f66b034a97fea7c37eed2528dc'
$block0=[scriptblock]::Create([IO.File]::ReadAllText($file0))

$realCim=Get-Command Get-CimInstance -CommandType Cmdlet
$actual=& $block0 | ConvertFrom-Json
if ($actual.schemaVersion -ne 1 -or $actual.os -cne 'Windows_NT' -or $actual.bootId -notmatch '^[0-9]+$') { throw 'Actual boot observation absent' }
Write-Output 'PASS actual read-only Windows CIM boot identity'
function Get-CimInstance {
 param($ClassName,$ErrorAction)
 $script:cimCalls++
 if ($ClassName -cne 'Win32_OperatingSystem' -or $ErrorAction -ne 'Stop') { throw 'Unexpected CIM command' }
 if ($script:bootCase -eq 'throw') { throw 'Public mocked CIM refusal' }
 if ($script:bootCase -eq 'null') { return [pscustomobject]@{LastBootUpTime=$null} }
 [pscustomobject]@{LastBootUpTime=[datetime]::SpecifyKind([datetime]'2026-09-27T00:00:00',[DateTimeKind]::Utc)}
}
foreach ($case in @('dateTime','null','throw','wrongOS')) {
 $script:bootCase=$case; $script:cimCalls=0; $failed=$false; $lines=@(); $env:OS='Windows_NT'
 if ($case -eq 'wrongOS') { $env:OS='Other' }
 try { $lines=@(& $block0) } catch { $failed=$true }
 if ($case -eq 'dateTime') {
  if ($failed -or $lines.Count -ne 1 -or $script:cimCalls -ne 1) { throw 'Boot positive command not observed' }
  $value=$lines[0] | ConvertFrom-Json
  if ($value.bootId -cne '134349408000000000') { throw 'Boot ID not actual FileTime' }
 } else {
  if (-not $failed -or $lines.Count -ne 0) { throw 'Invalid boot query passed' }
  if ($case -eq 'wrongOS' -and $script:cimCalls -ne 0) { throw 'Wrong OS reached CIM' }
  if ($case -ne 'wrongOS' -and $script:cimCalls -ne 1) { throw 'Boot mock was skipped' }
 }
 Write-Output "PASS boot query $case"
}
} finally {
 $env:OS=$originalOS
 Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
}
