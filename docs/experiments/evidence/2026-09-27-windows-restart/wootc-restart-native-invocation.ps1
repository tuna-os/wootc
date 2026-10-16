$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if ($env:OS -ne 'Windows_NT') { throw 'Expected Windows fixture' }
Write-Output "NATIVE_POWERSHELL $($PSVersionTable.PSVersion)"
$dir=Join-Path $env:TEMP "wootc-restart-mocks-$([guid]::NewGuid().ToString('N'))"
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
Write-Output 'SOURCE /tmp/wootc-boot-query.ps1 RAW b74a43410e579d013752acf77e181cc14542230904cfd4cfd83eacd74eb31324 STAGED a09d9cfd082041c2230051b0dd0a2fb11f4e88f66b034a97fea7c37eed2528dc'
$block0=[scriptblock]::Create([IO.File]::ReadAllText($file0))
$file1=Join-Path $dir 'source-1.ps1'
[IO.File]::WriteAllBytes($file1,[Convert]::FromBase64String('77u/DQokRXJyb3JBY3Rpb25QcmVmZXJlbmNlID0gIlN0b3AiDQpjbWQuZXhlIC9kIC9jICJzaHV0ZG93bi5leGUgL2EgPk5VTCAyPiYxIg0Kc2h1dGRvd24uZXhlIC9yIC90IDEgL2YNCmlmICgkTEFTVEVYSVRDT0RFIC1uZSAwKSB7IHRocm93ICJXaW5kb3dzIHJlc3RhcnQgcmVxdWVzdCByZWZ1c2VkIiB9DQpXcml0ZS1PdXRwdXQgIndpbmRvd3MtcmVzdGFydC1yZXF1ZXN0ZWQiDQo='))
if ((Get-FileHash -LiteralPath $file1).Hash.ToLowerInvariant() -cne '369ac347926e81f25acd7396366fb2365b62fd32bc0be9852f6bbc1d4a406fc6') { throw 'Staged hash mismatch' }
$tokens=$null; $parseErrors=$null; $null=[Management.Automation.Language.Parser]::ParseFile($file1,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'PS5.1 parse error' }
Write-Output 'SOURCE /tmp/wootc-restart-request.ps1 RAW c8e0c9b4be619925550a43cbc1e9e35185424a026fd919592e85f965acc64b2e STAGED 369ac347926e81f25acd7396366fb2365b62fd32bc0be9852f6bbc1d4a406fc6'
$block1=[scriptblock]::Create([IO.File]::ReadAllText($file1))

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
$env:OS=$originalOS
function cmd.exe {
 $script:cancelCalls++
 if (($args -join '|') -cne '/d|/c|shutdown.exe /a >NUL 2>&1') { throw 'Wrong cancellation command' }
 $global:LASTEXITCODE=1116
}
function shutdown.exe {
 $script:restartCalls++
 if (($args -join '|') -cne '/r|/t|1|/f') { throw 'Wrong restart request' }
 $global:LASTEXITCODE=$script:requestExit
}
foreach ($code in @(0,1,256)) {
 $script:requestExit=$code; $script:cancelCalls=0; $script:restartCalls=0; $failed=$false; $lines=@()
 if ((Get-Command cmd.exe).CommandType -ne 'Function' -or (Get-Command shutdown.exe).CommandType -ne 'Function') { throw 'Real shutdown cannot be called' }
 try { $lines=@(& $block1) } catch { $failed=$true }
 if ($script:cancelCalls -ne 1 -or $script:restartCalls -ne 1) { throw 'Restart mocks not observed' }
 if ($code -eq 0) {
  if ($failed -or $lines.Count -ne 1 -or $lines[0] -cne 'windows-restart-requested') { throw 'Successful exact acknowledgment absent' }
 } elseif (-not $failed -or $lines.Count -ne 0) { throw 'Failed restart produced acknowledgment' }
 Write-Output "PASS mocked restart native exit $code with ignored no-pending cancellation"
}
} finally {
 $env:OS=$originalOS
 Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
}
