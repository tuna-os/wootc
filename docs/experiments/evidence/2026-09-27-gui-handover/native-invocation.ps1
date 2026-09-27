$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT'){throw 'Expected native Windows'}
$d=Join-Path $env:TEMP "wootc-reboot-query-$([guid]::NewGuid().ToString('N'))"
if(Test-Path -LiteralPath $d){throw 'Existing temp directory'}
[IO.Directory]::CreateDirectory($d)|Out-Null
& icacls.exe $d /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' *> $null
if($LASTEXITCODE -ne 0){throw 'Private ACL failed'}
try {
$p=Join-Path $d 'directive.ps1'
[IO.File]::WriteAllBytes($p,[Convert]::FromBase64String('77u/DQokRXJyb3JBY3Rpb25QcmVmZXJlbmNlID0gIlN0b3AiDQokZGlyZWN0aXZlID0gIntgImFjdGlvbmAiOmAicmVib290YCJ9Ig0KU2V0LUNvbnRlbnQgLUxpdGVyYWxQYXRoIEM6XHdvb3RjXGUyZS1kcml2ZS5qc29uIC1WYWx1ZSAkZGlyZWN0aXZlIC1FbmNvZGluZyBhc2NpaQ0KJHJlYWRiYWNrID0gR2V0LUNvbnRlbnQgLUxpdGVyYWxQYXRoIEM6XHdvb3RjXGUyZS1kcml2ZS5qc29uIC1SYXcNCmlmICgkcmVhZGJhY2suVHJpbSgpIC1uZSAkZGlyZWN0aXZlKSB7IHRocm93ICJHVUkgcmVib290IGRpcmVjdGl2ZSByZWFkYmFjayBtaXNtYXRjaCIgfQ0KV3JpdGUtT3V0cHV0ICJndWktcmVib290LWRpcmVjdGl2ZS13cml0dGVuIg0K'))
if((Get-FileHash -LiteralPath $p).Hash.ToLowerInvariant() -ne '7262c507199ff8248371eee566bb4eb4c7404dab4ee383ef85eaa4dfaae985d2'){throw 'Source mismatch'}
$tokens=$null;$errors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Native parser rejected directive'}
$directiveScript=[ScriptBlock]::Create([IO.File]::ReadAllText($p))
function Set-Content {param($LiteralPath,$Value,$Encoding)
 $script:writes++
 if($LiteralPath -cne 'C:\wootc\e2e-drive.json' -or $Encoding -cne 'ascii' -or $Value -cne '{"action":"reboot"}'){throw 'Unexpected mocked write'}
 if($script:case -eq 'write-throw'){throw 'Public synthetic write failure'}
 $script:stored=$Value
}
function Get-Content {param($LiteralPath,[switch]$Raw)
 $script:reads++
 if($LiteralPath -cne 'C:\wootc\e2e-drive.json' -or -not $Raw){throw 'Unexpected mocked read'}
 if($script:case -eq 'read-throw'){throw 'Public synthetic read failure'}
 if($script:case -eq 'mismatch'){return '{}'}
 return "$script:stored`r`n"
}
foreach($case in @('matching','write-throw','read-throw','mismatch')){
 $script:case=$case;$script:writes=0;$script:reads=0;$script:stored=$null;$result=@();$failed=$false
 try{$result=@(& $directiveScript)}catch{$failed=$true}
 if($script:writes -ne 1){throw 'Mock write not executed'}
 if($case -eq 'matching'){
  if($failed -or $script:reads -ne 1 -or $result.Count -ne 1 -or $result[0] -cne 'gui-reboot-directive-written'){throw 'Matching directive lacks observed acknowledgment'}
 }else{
  if(-not $failed -or $result.Count -ne 0){throw 'Failed directive produced acknowledgment'}
  if($case -eq 'write-throw' -and $script:reads -ne 0){throw 'Write refusal reached read'}
  if($case -ne 'write-throw' -and $script:reads -ne 1){throw 'Mock read not executed'}
 }
 Write-Output "PASS native reboot directive $case"
}
Write-Output "PASS native PS $($PSVersionTable.PSVersion) exact353-byte directive parser and four mocked controls; no real C path access"
}finally{Microsoft.PowerShell.Management\Remove-Item -LiteralPath $d -Recurse -Force}
