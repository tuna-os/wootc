$ErrorActionPreference='Stop'
$originalOS=$env:OS
$d=Join-Path $env:TEMP "wootc-servicing-query-$([guid]::NewGuid().ToString('N'))"
if(Test-Path -LiteralPath $d){throw 'Existing temporary directory'}
[IO.Directory]::CreateDirectory($d)|Out-Null
& icacls.exe $d /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' *> $null
if($LASTEXITCODE -ne 0){throw 'Private ACL failed'}
try {
$p=Join-Path $d 'query.ps1'
[IO.File]::WriteAllBytes($p,[Convert]::FromBase64String('77u/JEVycm9yQWN0aW9uUHJlZmVyZW5jZSA9ICJTdG9wIg0KJHBlbmRpbmcgPSBAKCkNCmlmIChUZXN0LVBhdGggIkhLTE06XFNPRlRXQVJFXE1pY3Jvc29mdFxXaW5kb3dzXEN1cnJlbnRWZXJzaW9uXENvbXBvbmVudCBCYXNlZCBTZXJ2aWNpbmdcUmVib290UGVuZGluZyIpIHsgJHBlbmRpbmcgKz0gInNlcnZpY2luZyIgfQ0KaWYgKFRlc3QtUGF0aCAiSEtMTTpcU09GVFdBUkVcTWljcm9zb2Z0XFdpbmRvd3NcQ3VycmVudFZlcnNpb25cV2luZG93c1VwZGF0ZVxBdXRvIFVwZGF0ZVxSZWJvb3RSZXF1aXJlZCIpIHsgJHBlbmRpbmcgKz0gIndpbmRvd3MtdXBkYXRlIiB9DQokcmVzdWx0ID0gQHsgc2NoZW1hVmVyc2lvbiA9IDE7IG9zID0gJGVudjpPUzsgcGVuZGluZyA9IEAoJHBlbmRpbmcpIH0NCiRyZXN1bHQgfCBDb252ZXJ0VG8tSnNvbiAtQ29tcHJlc3MgLURlcHRoIDQNCg=='))
if((Get-FileHash -LiteralPath $p).Hash.ToLowerInvariant() -ne '67b3bf24f05cd47ac98eabdbe06567582ae5f736f43fd7817e835c42f50100d2'){throw 'Source mismatch'}
$tokens=$null;$errors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Actual native parser rejected query'}
$query=[ScriptBlock]::Create([IO.File]::ReadAllText($p))
function Test-Path {param([string]$Path)
 $script:calls++
 if($script:case -eq 'throw'){throw 'Public synthetic read failure'}
 if($Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'){return $script:case -in @('servicing','both')}
 if($Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'){return $script:case -in @('update','both')}
 throw 'Unexpected query path'
}
foreach($case in @('clean','servicing','update','both','throw','wrong-os')){
 $script:case=$case;$script:calls=0;$env:OS='Windows_NT'
 if($case -eq 'wrong-os'){$env:OS='Other'}
 $failed=$false
 try{$json=& $query}catch{$failed=$true;if($case -ne 'throw'){throw}}
 if($case -eq 'throw'){if(-not $failed -or $script:calls -ne 1){throw 'Unreadable query passed'};Write-Output 'PASS native servicing query throwing read refusal';continue}
 if($failed -or $script:calls -ne 2){throw 'Mock query was not executed'}
 $r=$json|ConvertFrom-Json
 $expected=@();if($case -in @('servicing','both')){$expected+='servicing'};if($case -in @('update','both')){$expected+='windows-update'}
 if($r.schemaVersion -ne 1 -or ($r.pending -isnot [Array]) -or (($r.pending -join ',') -ne ($expected -join ','))){throw 'Incorrect native array receipt'}
 if($case -eq 'wrong-os' -and $r.os -eq 'Windows_NT'){throw 'OS mismatch concealed'}
 Write-Output "RECEIPT $case $json"
}
Write-Output "PASS native PS $($PSVersionTable.PSVersion) exact query parser and six mock controls"
}finally{$env:OS=$originalOS;Microsoft.PowerShell.Management\Remove-Item -LiteralPath $d -Recurse -Force}
