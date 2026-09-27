$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT'){throw 'Expected actual Windows identity'}
$d=Join-Path $env:TEMP "wootc-bound-drive-query-$([guid]::NewGuid().ToString('N'))"
if(Test-Path -LiteralPath $d){throw 'Existing temp directory'}
[IO.Directory]::CreateDirectory($d)|Out-Null
& icacls.exe $d /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' *> $null
if($LASTEXITCODE -ne 0){throw 'Private ACL failed'}
try {
$source0=Join-Path $d 'install-command.ps1'
[IO.File]::WriteAllBytes($source0,[Convert]::FromBase64String('77u/JEVycm9yQWN0aW9uUHJlZmVyZW5jZT0nU3RvcCcNCiR3YW50ZWQ9W1RleHQuRW5jb2RpbmddOjpVVEY4LkdldFN0cmluZyhbQ29udmVydF06OkZyb21CYXNlNjRTdHJpbmcoJ2V5SnpZMmhsYldGV1pYSnphVzl1SWpveExDSnlkVzVKWkNJNkluQjFZbXhwWXkxdVlYUnBkbVV0WTNWeWNtVnVkQ0lzSW1ScGNtVmpkR2wyWlVsa0lqb2lOemxqTlRSbU16VTBNV05qTkdOak5XRmhNV1k0WWpRME16RTRZalV3TUdJaUxDSmhZM1JwYjI0aU9pSnBibk4wWVd4c0lpd2lhVzFoWjJVaU9pSm5hR055TG1sdkwzUjFibUV0YjNNdmVXVnNiRzkzWm1sdU9tZHViMjFsSWl3aWRYTmxjbTVoYldVaU9pSjNiMjkwWXlJc0luQmhjM04zYjNKa0lqb2lkMjl2ZEdNdFpUSmxMWEJoYzNNaUxDSm9iM04wYm1GdFpTSTZJbmR2YjNSakxYUmxjM1FpZlE9PScpKQ0KU2V0LUNvbnRlbnQgLUxpdGVyYWxQYXRoIEM6XHdvb3RjXGUyZS1kcml2ZS5qc29uIC1WYWx1ZSAkd2FudGVkIC1FbmNvZGluZyBVVEY4DQokYWN0dWFsPUdldC1Db250ZW50IC1MaXRlcmFsUGF0aCBDOlx3b290Y1xlMmUtZHJpdmUuanNvbiAtUmF3DQppZiAoJGFjdHVhbC5UcmltRW5kKFtjaGFyXTEzLFtjaGFyXTEwKSAtY25lICR3YW50ZWQpIHsgdGhyb3cgJ0RpcmVjdGl2ZSByZWFkYmFjayBjaGFuZ2VkJyB9DQpXcml0ZS1PdXRwdXQgJ2d1aS1pbnN0YWxsLWRpcmVjdGl2ZS13cml0dGVuJw=='))
if((Get-FileHash -LiteralPath $source0).Hash.ToLowerInvariant() -ne '6982e241c627ea60c17a73efb4bc6e72998ce6f38e0c5f450cea6cc101eaf480'){throw 'Staged source hash changed'}
$source1=Join-Path $d 'reboot-command.ps1'
[IO.File]::WriteAllBytes($source1,[Convert]::FromBase64String('77u/JGVuY29kZWQ9J2V5SnpZMmhsYldGV1pYSnphVzl1SWpveExDSnlkVzVKWkNJNkluQjFZbXhwWXkxdVlYUnBkbVV0WTNWeWNtVnVkQ0lzSW1ScGNtVmpkR2wyWlVsa0lqb2lOemxqTlRSbU16VTBNV05qTkdOak5XRmhNV1k0WWpRME16RTRZalV3TUdJaUxDSmhZM1JwYjI0aU9pSnlaV0p2YjNRaWZRPT0nDQoNCiRFcnJvckFjdGlvblByZWZlcmVuY2UgPSAiU3RvcCINCiRkaXJlY3RpdmUgPSBbVGV4dC5FbmNvZGluZ106OlVURjguR2V0U3RyaW5nKFtDb252ZXJ0XTo6RnJvbUJhc2U2NFN0cmluZygkZW5jb2RlZCkpDQpTZXQtQ29udGVudCAtTGl0ZXJhbFBhdGggQzpcd29vdGNcZTJlLWRyaXZlLmpzb24gLVZhbHVlICRkaXJlY3RpdmUgLUVuY29kaW5nIGFzY2lpDQokcmVhZGJhY2sgPSBHZXQtQ29udGVudCAtTGl0ZXJhbFBhdGggQzpcd29vdGNcZTJlLWRyaXZlLmpzb24gLVJhdw0KaWYgKCRyZWFkYmFjay5UcmltKCkgLW5lICRkaXJlY3RpdmUpIHsgdGhyb3cgIkdVSSByZWJvb3QgZGlyZWN0aXZlIHJlYWRiYWNrIG1pc21hdGNoIiB9DQpXcml0ZS1PdXRwdXQgImd1aS1yZWJvb3QtZGlyZWN0aXZlLXdyaXR0ZW4iDQo='))
if((Get-FileHash -LiteralPath $source1).Hash.ToLowerInvariant() -ne '6ba36e90e36f14c77d9ec53a66d28aa5df0b8189b9ee07e3dab486985f2e089a'){throw 'Staged source hash changed'}
function Set-Content {param($LiteralPath,$Value,$Encoding)
 $script:writes++
 if($LiteralPath -cne 'C:\wootc\e2e-drive.json'){throw 'Unexpected mocked write path'}
 $r=$Value|ConvertFrom-Json
 if($r.schemaVersion -ne 1 -or $r.runId -cne 'public-native-current' -or $r.directiveId -cne '79c54f3541cc4cc5aa1f8b44318b500b' -or $r.action -cne $script:action){throw 'Wrong actual bound directive'}
 if($script:action -eq 'install' -and ($Encoding -cne 'UTF8' -or $r.username -cne 'wootc' -or $r.password -cne 'wootc-e2e-pass' -or $r.image -cne 'ghcr.io/tuna-os/yellowfin:gnome')){throw 'Wrong public install fixture or encoding'}
 if($script:action -eq 'reboot' -and $Encoding -cne 'ascii'){throw 'Wrong reboot encoding'}
 if($script:case -eq 'write-throw'){throw 'Public synthetic write refusal'}
 $script:stored=$Value
}
function Get-Content {param($LiteralPath,[switch]$Raw)
 $script:reads++
 if($LiteralPath -cne 'C:\wootc\e2e-drive.json' -or -not $Raw){throw 'Unexpected mocked read path'}
 if($script:case -eq 'read-throw'){throw 'Public synthetic read refusal'}
 if($script:case -eq 'mismatch'){return '{}'}
 return "$script:stored`r`n"
}
$index=0
foreach($path in @($source0,$source1)){
 $tokens=$null;$errors=$null
 $null=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'Actual native parser rejected source'}
 $command=[ScriptBlock]::Create([IO.File]::ReadAllText($path))
 $script:action='install';$ack='gui-install-directive-written'
 if($index -eq 1){$script:action='reboot';$ack='gui-reboot-directive-written'}
 foreach($case in @('matching','write-throw','read-throw','mismatch')){
  $script:case=$case;$script:writes=0;$script:reads=0;$script:stored=$null;$result=@();$failed=$false
  try{$result=@(& $command)}catch{$failed=$true}
  if($script:writes -ne 1){throw 'Actual mock write was not executed'}
  if($case -eq 'matching'){
   if($failed -or $script:reads -ne 1 -or $result.Count -ne 1 -or $result[0] -isnot [string] -or $result[0] -cne $ack){throw 'No typed positive readback acknowledgment'}
  }else{
   if(-not $failed -or $result.Count -ne 0){throw 'Refusal produced acknowledgment'}
   if($case -eq 'write-throw' -and $script:reads -ne 0){throw 'Write refusal reached read'}
   if($case -ne 'write-throw' -and $script:reads -ne 1){throw 'Actual mock read was not executed'}
  }
  Write-Output "PASS native bound $script:action directive $case"
 }
 $index++
}
Write-Output "PASS actual PS $($PSVersionTable.PSVersion) two captured scripts parsed and eight mock controls; public fixture only; no actual C paths"
}finally{Microsoft.PowerShell.Management\Remove-Item -LiteralPath $d -Recurse -Force}
